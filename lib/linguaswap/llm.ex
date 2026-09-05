defmodule Linguaswap.LLM do
  @moduledoc """
  The one way the app talks to a language model.

  Everything provider-independent lives here — resolving configuration, the
  spending guard, the rate limit — and everything provider-specific lives behind
  `Linguaswap.LLM.Provider`. `Linguaswap.Dictionary` therefore never learns
  whose model answered it, and changing that answer is a config line.

  There is exactly one call shape, `complete/3`: send a prompt, get back the
  JSON object a schema describes. That is all the dictionary pipeline needs — it
  asks for a batch of entries to be filled in and gets structured data, never
  prose.

  Two things hold for every provider:

    * **Every request passes the budget.** `Linguaswap.LLM.Budget` is asked
      before the call and told what it cost afterwards. A run cannot spend past
      its cap, and a caller that hits the rate limit waits rather than fails.
    * **No key means no request.** With no `:api_key` configured the client
      returns `{:error, :missing_api_key}` and never reaches the network, which
      is what keeps the test suite offline.

  ## Configuration

      config :linguaswap, Linguaswap.LLM,
        provider: Linguaswap.LLM.Provider.Anthropic,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        model: "claude-opus-5",
        effort: :low,
        requests_per_minute: 20,
        cost_cap_usd: 5.0

  Keys other than `:provider`, `:requests_per_minute` and `:cost_cap_usd` are
  passed through to the provider, which reads the ones it knows.
  """

  alias Linguaswap.LLM.Budget
  alias Linguaswap.LLM.Provider

  require Logger

  @default_provider Provider.Anthropic

  # How long a caller may be held waiting for a rate limit slot before the
  # request is abandoned. Longer than one window, so a full window drains.
  @max_wait_ms 90_000

  @doc """
  Sends one prompt and returns the decoded JSON object the model produced.

  `schema` is a JSON Schema map describing the object to return. Options
  override the configured values for this call, and anything the provider
  understands may be passed:

    * `:system` — system prompt (defaults to none)
    * `:model`, `:max_tokens`, `:effort` — override the configured values
    * `:provider` — override the configured provider module
    * `:budget` — the budget process to charge (defaults to the named one)

  Returns `{:ok, map}`, or `{:error, reason}` where reason is
  `:missing_api_key`, `:cost_cap_reached`, `:rate_limited`, `{:status, code,
  body}`, `{:refusal, category}`, `{:invalid_json, text}` or an exception.
  """
  def complete(prompt, schema, opts \\ []) do
    config = config(opts)
    provider = config[:provider] || @default_provider
    budget = opts[:budget] || Budget

    with :ok <- await_slot(budget, @max_wait_ms),
         {:ok, %{data: data, model: model, usage: usage}} <-
           provider.complete(prompt, schema, config) do
      warn_if_substituted(config[:model], model)
      Budget.record(budget, model, usage)
      {:ok, data}
    end
  end

  # A server-side refusal fallback answers on a different model without saying
  # so anywhere the caller would notice. That matters twice over: the data was
  # produced by a model nobody chose, and it is billed at that model's rate. So
  # it is said out loud.
  defp warn_if_substituted(requested, answered)
       when is_binary(requested) and is_binary(answered) and requested != answered do
    Logger.warning(
      "#{requested} declined or could not answer; #{answered} responded instead. " <>
        "The data this produced came from #{answered}."
    )
  end

  defp warn_if_substituted(_requested, _answered), do: :ok

  @doc """
  Whether the client is configured to reach a model at all.

  Callers use this to fail early with a clear message instead of walking a
  dictionary to discover the key is missing on the first row.
  """
  def configured? do
    case config([])[:api_key] do
      key when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  @doc """
  The provider module in force, for a caller that wants to name it in a message.
  """
  def provider, do: config([])[:provider] || @default_provider

  # Call options win over the application environment, and `nil` values in the
  # options are ignored rather than blanking a configured value — callers pass
  # `model: opts[:model]` freely.
  defp config(opts) do
    overrides = Enum.reject(opts, fn {_key, value} -> is_nil(value) end)

    :linguaswap
    |> Application.get_env(__MODULE__, [])
    |> Keyword.merge(overrides)
  end

  # Waits for a rate limit slot, giving up rather than blocking a run forever.
  defp await_slot(budget, remaining_ms) do
    case Budget.checkout(budget) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}

      {:wait, _ms} when remaining_ms <= 0 ->
        {:error, :rate_limited}

      {:wait, ms} ->
        wait = min(ms, remaining_ms)
        Logger.debug("LLM rate limit reached, waiting #{wait}ms")
        Process.sleep(wait)
        await_slot(budget, remaining_ms - wait)
    end
  end
end
