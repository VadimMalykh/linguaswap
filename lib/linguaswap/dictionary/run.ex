defmodule Linguaswap.Dictionary.Run do
  @moduledoc """
  One dictionary job at a time, owned by the server rather than by a shell.

  Generation started life as a `mix` flag, which is a fine way to do a thing
  once and a poor way to do it repeatedly: adding a language, extending a word
  list or re-running a batch after a prompt change are all ordinary operations,
  and none of them should need a terminal and a `docker compose exec`. This
  process is what a dashboard button talks to.

  Three properties it exists to provide:

    * **The run outlives the page.** It is a process, not a `Task` inside a
      LiveView, so closing the tab does not abandon work that is spending money
      — and re-opening the page rejoins the run in progress rather than
      starting a second one.
    * **Only one at a time.** Two concurrent runs would race for the same
      unqueued entries, generate them twice and pay twice. `start/2` refuses
      rather than queueing, because the honest answer to "generate this again"
      is that it is already happening.
    * **Its own allowance.** Each run gets a fresh `Linguaswap.LLM.Budget` with
      its own cap. The global budget is scoped to the process lifetime, which
      is right for a `mix` task and wrong for a server that runs for months:
      there, a lifetime cap means generation quietly stops working forever once
      the app has spent it.

  Progress is broadcast on `"dictionary:run"`, so any number of viewers see the
  same run advance.

  ## Two jobs, one server

  It runs generation (`:generate`) and verification (`:verify`), and the reason
  they share a process rather than getting one each is the "only one at a time"
  property above. They are not independent: verification reads exactly the rows
  generation writes, so a verify pass racing a generate pass over the same pair
  would be checking a moving target, and both spend money against a budget
  scoped to one run. One server means the second job waits, which is the honest
  answer rather than an artificial restriction.
  """

  use GenServer

  alias Linguaswap.Dictionary
  alias Linguaswap.LLM.Budget
  alias Linguaswap.Verification
  alias Phoenix.PubSub

  require Logger

  @topic "dictionary:run"

  # Measured, not guessed: a real 20-entry run on `claude-opus-4-8` cost $0.03,
  # so this is $0.0015 per entry including the thinking tokens that dominate
  # the output side. Used only to put a number next to the button before a run
  # starts — what a run actually cost comes from its budget afterwards, and
  # that figure is the one shown once it finishes.
  @estimated_cost_per_entry 0.0015

  # Verification's per-entry figure is an upper bound rather than an estimate.
  # Only the claims the local tiers could not settle reach the round trip, and
  # they are analysed 15 surfaces to a request against generation's 20 — so for
  # a pair with a paradigm file this is wrong by a wide margin in the cheap
  # direction, and for a pair without one it is roughly right. Quoting the
  # ceiling is the right way round for a number that appears next to a button
  # that spends money.
  @estimated_verification_cost_per_entry 0.001

  defstruct status: :idle,
            job: :generate,
            language_pair: nil,
            total: 0,
            done: 0,
            generated: 0,
            failed: [],
            result: %{},
            stopped: nil,
            started_at: nil,
            finished_at: nil,
            spent_usd: 0.0,
            budget: nil,
            task: nil

  ## Client

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)
  end

  @doc """
  Starts a job for a language pair.

  `:job` picks which one — `:generate` (the default) or `:verify` — and the
  rest of the options are passed through to `Linguaswap.Dictionary.generate/2`
  or `Linguaswap.Verification.verify/2`; `:limit` is the one a caller usually
  sets. Returns `{:error, :already_running}` rather than starting a second run,
  and `{:error, :missing_api_key}` rather than starting one that cannot work.

  Verification may be started without an API key when the pair's chain has a
  local tier to run: `en-es` gets real answers out of a paradigm file and a
  frequency list with nothing configured at all, and refusing to start would be
  refusing to do work that costs nothing.
  """
  # Written out rather than using two default arguments: `start(server \\ M,
  # pair, opts \\ [])` compiles, and then `start("en-es", limit: 20)` silently
  # binds "en-es" as the server and crashes inside `GenServer.whereis/1`.
  def start(language_pair) when is_binary(language_pair) do
    start(__MODULE__, language_pair, [])
  end

  def start(language_pair, opts) when is_binary(language_pair) and is_list(opts) do
    start(__MODULE__, language_pair, opts)
  end

  def start(server, language_pair) when is_binary(language_pair) do
    start(server, language_pair, [])
  end

  def start(server, language_pair, opts) when is_binary(language_pair) and is_list(opts) do
    GenServer.call(server, {:start, language_pair, opts})
  end

  @doc """
  Asks the current run to stop after the batch it is in.

  Deliberately not an interrupt: the request in flight has already been paid
  for, so it is allowed to finish and its results are kept.
  """
  def cancel(server \\ __MODULE__) do
    GenServer.call(server, :cancel)
  end

  @doc """
  What the run is doing, or the result of the last one.
  """
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Subscribes the caller to run progress.
  """
  def subscribe do
    PubSub.subscribe(Linguaswap.PubSub, @topic)
  end

  @doc """
  Roughly what running a job over `count` entries will cost, in dollars.

  An estimate for a button label, not an accounting figure — the real number is
  in `status/0` once a run has finished.
  """
  def estimate_cost(count, job \\ :generate)

  def estimate_cost(count, :generate) when is_integer(count) and count >= 0 do
    count * @estimated_cost_per_entry
  end

  def estimate_cost(count, :verify) when is_integer(count) and count >= 0 do
    count * @estimated_verification_cost_per_entry
  end

  ## Server

  @impl GenServer
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl GenServer
  def handle_call({:start, _pair, _opts}, _from, %{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:start, language_pair, opts}, _from, state) do
    if runnable?(language_pair, opts[:job] || :generate) do
      {:reply, :ok, begin_run(state, language_pair, opts)}
    else
      {:reply, {:error, :missing_api_key}, state}
    end
  end

  def handle_call(:cancel, _from, %{status: :running} = state) do
    # The task reads this through `should_continue`, so cancelling is a state
    # change here rather than a message the task has to be waiting for.
    {:reply, :ok, broadcast(%{state | status: :cancelling})}
  end

  def handle_call(:cancel, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  # Progress from the running task.
  @impl GenServer
  def handle_info({:progress, done}, state) do
    {:noreply, broadcast(%{state | done: done})}
  end

  def handle_info({:finished, result}, state) do
    spent =
      case state.budget do
        nil -> state.spent_usd
        budget -> Budget.stats(budget).spent_usd
      end

    state = %{
      state
      | status: :finished,
        generated: Map.get(result, :generated, Map.get(result, :approved, 0)),
        failed: Map.get(result, :failed, []),
        result: result,
        stopped: result.stopped,
        finished_at: DateTime.utc_now(),
        spent_usd: spent,
        task: nil
    }

    stop_budget(state)
    {:noreply, broadcast(%{state | budget: nil})}
  end

  # The task crashed rather than returning. Reported as a finished run with a
  # reason, because a dashboard that shows "running" forever is worse than one
  # that shows a failure.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{task: pid} = state)
      when reason != :normal do
    Logger.error("Dictionary #{state.job} run crashed: #{inspect(reason)}")

    stop_budget(state)

    {:noreply,
     broadcast(%{
       state
       | status: :finished,
         stopped: {:crashed, reason},
         finished_at: DateTime.utc_now(),
         task: nil,
         budget: nil
     })}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp begin_run(state, language_pair, opts) do
    owner = self()
    job = opts[:job] || :generate

    {:ok, budget} =
      Budget.start_link(
        name: :"dictionary_run_budget_#{System.unique_integer([:positive])}",
        config: Application.get_env(:linguaswap, Linguaswap.LLM, [])
      )

    total = length(pending(job, language_pair, opts[:limit]))

    {:ok, pid} =
      Task.start(fn ->
        result =
          run(
            job,
            language_pair,
            opts
            |> Keyword.delete(:job)
            |> Keyword.put(:budget, budget)
            |> Keyword.put(:should_continue, fn -> GenServer.call(owner, :status).running? end)
            |> Keyword.put(:on_batch, fn {done, _total} -> send(owner, {:progress, done}) end)
          )

        send(owner, {:finished, result})
      end)

    Process.monitor(pid)

    broadcast(%{
      state
      | status: :running,
        job: job,
        language_pair: language_pair,
        total: total,
        done: 0,
        generated: 0,
        failed: [],
        result: %{},
        stopped: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        spent_usd: 0.0,
        budget: budget,
        task: pid
    })
  end

  defp run(:generate, language_pair, opts), do: Dictionary.generate(language_pair, opts)
  defp run(:verify, language_pair, opts), do: Verification.verify(language_pair, opts)

  @doc """
  Entries a job would work on, so a caller can size and price it before asking.
  """
  def pending(job, language_pair, limit \\ nil)

  def pending(:generate, language_pair, limit) do
    Dictionary.entries_needing_generation(language_pair, limit)
  end

  def pending(:verify, language_pair, limit) do
    Verification.entries_needing_verification(language_pair, limit)
  end

  # Generation cannot happen without a model. Verification can: for `en-es` the
  # first three tiers are a paradigm file and a frequency list, and refusing to
  # run them because no key is configured would be refusing free work.
  defp runnable?(_language_pair, :generate), do: Linguaswap.LLM.configured?()

  defp runnable?(language_pair, :verify) do
    language_pair
    |> Verification.availability()
    |> Enum.any?(fn {_verifier, available?} -> available? end)
  end

  defp stop_budget(%{budget: nil}), do: :ok

  defp stop_budget(%{budget: budget}) do
    if Process.alive?(budget), do: GenServer.stop(budget)
    :ok
  end

  # The struct carries a budget pid and a task pid that no caller should see or
  # depend on; this is the shape the dashboard renders.
  defp public(state) do
    %{
      status: state.status,
      running?: state.status == :running,
      job: state.job,
      language_pair: state.language_pair,
      total: state.total,
      done: state.done,
      generated: state.generated,
      failed: state.failed,
      result: state.result,
      stopped: state.stopped,
      started_at: state.started_at,
      finished_at: state.finished_at,
      spent_usd: state.spent_usd
    }
  end

  defp broadcast(state) do
    PubSub.broadcast(Linguaswap.PubSub, @topic, {:dictionary_run, public(state)})
    state
  end
end
