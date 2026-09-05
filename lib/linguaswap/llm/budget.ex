defmodule Linguaswap.LLM.Budget do
  @moduledoc """
  The spending and rate limit guard in front of the Claude API.

  Generation runs over a dictionary, so the natural failure mode is not one
  expensive call but a loop of cheap ones: a typo in a `--generate-limit`, a
  retry that never gives up, a rebuilt dictionary regenerating every row. This
  process is what makes that bounded, and it is deliberately the only way the
  rest of the app is allowed to reach the API — `Linguaswap.LLM` asks here
  before every request and reports what the request actually cost after it.

  Two limits, both configured under `config :linguaswap, Linguaswap.LLM`:

    * `:requests_per_minute` — a sliding one-minute window. `checkout/1`
      returns `{:wait, ms}` rather than an error when the window is full, so a
      caller working through a batch paces itself instead of failing.
    * `:cost_cap_usd` — total spend allowed for the lifetime of the process,
      which for a `mix` task is the lifetime of the run. Reaching it is an
      error, not a wait: no amount of waiting brings the money back.

  Cost is computed from the usage the API reports, priced per model from
  `:prices` (dollars per million tokens, `{input, output}`).

  An **unpriced model is billed at the most expensive rate known**, and warned
  about. That is the opposite of the obvious choice, and it is deliberate: this
  process is a safety net, and the first version billed unknown models at zero
  "rather than guessing". A server-side refusal fallback then answered a real
  run on a model that was not in the table, and the run recorded a spend of
  exactly $0.00 — the cap silently stopped existing. Over-charging a model
  nobody has priced yet ends a run early, which is recoverable; under-charging
  it removes the only thing standing between a loop and a bill.
  """

  use GenServer

  require Logger

  @window_ms 60_000

  @default_requests_per_minute 20
  @default_cost_cap_usd 5.0

  # Dollars per million tokens, {input, output}. Anthropic list prices.
  #
  # Fallback models belong here too: a refusal fallback can put a model on the
  # bill that no configuration ever named, and an unpriced model distorts the
  # cap (see the moduledoc).
  @default_prices %{
    "claude-opus-5" => {5.0, 25.0},
    "claude-opus-4-8" => {5.0, 25.0},
    "claude-opus-4-7" => {5.0, 25.0},
    "claude-sonnet-5" => {2.0, 10.0},
    "claude-haiku-4-5" => {1.0, 5.0}
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Asks permission to make one request.

  Returns `:ok`, `{:wait, milliseconds}` when the rate limit window is full, or
  `{:error, :cost_cap_reached}` when the run has spent its allowance.
  """
  def checkout(server \\ __MODULE__) do
    GenServer.call(server, :checkout)
  end

  @doc """
  Records what a completed request cost, from the API's own usage report.

  Accepts the `usage` object as the API returns it. Unknown shapes are counted
  as zero tokens rather than raising: a mis-parsed usage block should not take
  down a generation run that already succeeded.
  """
  def record(server \\ __MODULE__, model, usage) do
    GenServer.cast(server, {:record, model, usage})
  end

  @doc """
  What the run has spent so far, and what is left.
  """
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @doc """
  Forgets the spend and the rate limit window.

  For tests and for a long-lived node that wants a fresh allowance; a `mix`
  task gets one for free by starting a new process.
  """
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @doc """
  Price of a request in dollars, given a model and a usage map.
  """
  def cost(model, usage, prices \\ @default_prices) do
    {input_price, output_price} = price_for(model, prices)

    input = usage_tokens(usage, ["input_tokens", "cache_creation_input_tokens"])
    cached = usage_tokens(usage, ["cache_read_input_tokens"])
    output = usage_tokens(usage, ["output_tokens"])

    # Cache reads are a tenth of the input price. Nothing here caches yet, so
    # this only matters the day something does.
    (input * input_price + cached * input_price * 0.1 + output * output_price) / 1_000_000
  end

  @doc """
  The `{input, output}` price for a model, in dollars per million tokens.

  An unknown model is charged at the highest rate in the table. See the
  moduledoc for why that is the safe direction to be wrong in.
  """
  def price_for(model, prices \\ @default_prices) do
    case Map.fetch(prices, model) do
      {:ok, price} ->
        price

      :error ->
        Logger.warning(
          "No price configured for #{inspect(model)}; billing it at the highest known rate " <>
            "so the cost cap still means something. Add it to :prices to fix the accounting."
        )

        Enum.max_by(Map.values(prices), fn {input, output} -> input + output end, fn ->
          {0.0, 0.0}
        end)
    end
  end

  defp usage_tokens(usage, keys) when is_map(usage) do
    Enum.reduce(keys, 0, fn key, total ->
      case Map.get(usage, key) || Map.get(usage, String.to_atom(key)) do
        count when is_integer(count) and count > 0 -> total + count
        _ -> total
      end
    end)
  end

  defp usage_tokens(_usage, _keys), do: 0

  @impl GenServer
  def init(opts) do
    config = Keyword.get(opts, :config, Application.get_env(:linguaswap, Linguaswap.LLM, []))

    {:ok,
     %{
       requests_per_minute:
         Keyword.get(config, :requests_per_minute, @default_requests_per_minute),
       cost_cap_usd: Keyword.get(config, :cost_cap_usd, @default_cost_cap_usd),
       prices: Keyword.get(config, :prices, @default_prices),
       spent_usd: 0.0,
       requests: 0,
       window: []
     }}
  end

  @impl GenServer
  def handle_call(:checkout, _from, state) do
    now = System.monotonic_time(:millisecond)
    window = Enum.filter(state.window, &(now - &1 < @window_ms))

    cond do
      state.spent_usd >= state.cost_cap_usd ->
        {:reply, {:error, :cost_cap_reached}, %{state | window: window}}

      length(window) < state.requests_per_minute ->
        {:reply, :ok, %{state | window: [now | window]}}

      true ->
        # The oldest request in the window is the one whose expiry frees a slot.
        oldest = Enum.min(window)
        {:reply, {:wait, @window_ms - (now - oldest) + 1}, %{state | window: window}}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       spent_usd: state.spent_usd,
       remaining_usd: max(state.cost_cap_usd - state.spent_usd, 0.0),
       cost_cap_usd: state.cost_cap_usd,
       requests: state.requests
     }, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | spent_usd: 0.0, requests: 0, window: []}}
  end

  @impl GenServer
  def handle_cast({:record, model, usage}, state) do
    spent = state.spent_usd + cost(model, usage, state.prices)

    if spent >= state.cost_cap_usd and state.spent_usd < state.cost_cap_usd do
      Logger.warning(
        "LLM cost cap of $#{state.cost_cap_usd} reached after #{state.requests + 1} requests"
      )
    end

    {:noreply, %{state | spent_usd: spent, requests: state.requests + 1}}
  end
end
