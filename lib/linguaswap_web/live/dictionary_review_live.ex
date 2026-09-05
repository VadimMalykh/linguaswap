defmodule LinguaswapWeb.DictionaryReviewLive do
  @moduledoc """
  The dictionary workbench: generate entries, then review what came back.

  Both halves are here on purpose. Generation and review are one loop — you
  generate a batch, read it, approve or reject, and generate the next — and
  splitting them across two pages would mean the person doing the reading has
  to go somewhere else to ask for more. It also puts the cost estimate directly
  above the button that spends the money.

  Generated forms are not served until someone has looked at them, and this is
  where they are looked at. One row per entry: the English word, its part of
  speech, the translation it already had, and every target-side form the model
  proposed, shown in a sentence-shaped way — "she was …" next to the past form
  — because a form is only wrong in context.

  Approving serves the forms; rejecting clears them and keeps the entry out of
  the next generation pass. Both are one click, because a reviewer working
  through a frequency list is doing hundreds of them.
  """

  use LinguaswapWeb, :live_view

  alias Linguaswap.Dictionary
  alias Linguaswap.Dictionary.Run
  alias Linguaswap.LLM
  alias Linguaswap.Repo
  alias Linguaswap.Vocabulary
  alias Linguaswap.Vocabulary.Word

  @page_size 25

  # How many entries a run may be asked for. "Everything" is deliberately last
  # and not the default: the first thing to do with a new language pair is
  # generate twenty and read them.
  @batch_choices [20, 100, 500]

  # What each form key means for the reader, as the English frame that asks for
  # it. A form is judged in the slot it will appear in, not as a bare word.
  @form_labels %{
    "plural" => "plural",
    "third_person" => "he / she ___",
    "past" => "past tense",
    "past_participle" => "has ___",
    "gerund" => "is ___ing",
    "comparative" => "more ___",
    "superlative" => "most ___"
  }

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    if connected?(socket), do: Run.subscribe()

    {:ok,
     socket
     |> assign(
       language_pair: Vocabulary.language_pair_for_target(user.target_language),
       language_pairs: Vocabulary.language_pairs(),
       batch_choices: @batch_choices,
       count: hd(@batch_choices),
       configured?: LLM.configured?(),
       run: Run.status()
     )
     |> load_queue()}
  end

  # A run belongs to the server, not to this page, so every viewer sees the same
  # one advance and a reload rejoins one already in progress.
  def handle_info({:dictionary_run, run}, socket) do
    socket = assign(socket, run: run)

    # Newly generated entries are exactly what this page exists to show, so the
    # queue is re-read as they land rather than on a refresh.
    {:noreply, if(run.status == :finished, do: load_queue(socket), else: socket)}
  end

  def handle_event("select-pair", %{"language_pair" => pair}, socket) do
    if pair in Vocabulary.language_pairs() do
      {:noreply, socket |> assign(language_pair: pair) |> load_queue()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select-count", %{"count" => count}, socket) do
    case Integer.parse(count) do
      {parsed, ""} when parsed > 0 -> {:noreply, assign(socket, count: parsed)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("generate", _params, socket) do
    case Run.start(socket.assigns.language_pair, limit: socket.assigns.count) do
      :ok ->
        {:noreply, assign(socket, run: Run.status())}

      {:error, :already_running} ->
        {:noreply, put_flash(socket, :error, "A run is already in progress")}

      {:error, :missing_api_key} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No API key is configured, so there is nothing to generate with"
         )}
    end
  end

  def handle_event("cancel", _params, socket) do
    Run.cancel()
    {:noreply, assign(socket, run: Run.status())}
  end

  def handle_event("approve", %{"id" => id}, socket) do
    {:noreply, review(socket, id, &Dictionary.approve/1, "Approved")}
  end

  def handle_event("reject", %{"id" => id}, socket) do
    {:noreply, review(socket, id, &Dictionary.reject/1, "Rejected")}
  end

  # A reviewer only ever acts on a row that is in front of them, so the entry is
  # re-read scoped to the queue's own language pair rather than trusted from the
  # form.
  defp review(socket, id, action, verb) do
    case Repo.get_by(Word, id: id, language_pair: socket.assigns.language_pair) do
      nil ->
        put_flash(socket, :error, "That entry is no longer in the queue")

      word ->
        case action.(word) do
          {:ok, updated} ->
            socket
            |> put_flash(:info, "#{verb} #{updated.original_word}")
            |> load_queue()

          {:error, _changeset} ->
            put_flash(socket, :error, "Could not update #{word.original_word}")
        end
    end
  end

  defp load_queue(socket) do
    language_pair = socket.assigns.language_pair
    stats = Dictionary.review_stats(language_pair)

    assign(socket,
      entries: Dictionary.entries_pending_review(language_pair, @page_size),
      stats: stats,
      # Never offer to generate more than there is, so the estimate on the
      # button is the estimate for what will actually happen.
      queued: stats.ungenerated
    )
  end

  defp will_generate(count, queued), do: min(count, queued)

  defp progress_percent(%{total: total, done: done}) when total > 0 do
    min(round(done / total * 100), 100)
  end

  defp progress_percent(_run), do: 0

  defp money(amount) when is_number(amount) do
    cond do
      amount == 0 -> "$0.00"
      amount < 0.01 -> "under $0.01"
      true -> "$#{:erlang.float_to_binary(amount / 1, decimals: 2)}"
    end
  end

  defp describe_stop(:cancelled), do: "stopped on request"
  defp describe_stop(:cost_cap_reached), do: "stopped at the cost cap"
  defp describe_stop(:missing_api_key), do: "no API key is configured"

  defp describe_stop(:first_batch_failed),
    do: "nothing in the first batch worked, so the rest was not attempted"

  defp describe_stop({:refusal, category}), do: "the model declined the request (#{category})"
  defp describe_stop({:status, status, _body}), do: "the API returned #{status}"
  defp describe_stop({:crashed, _reason}), do: "the run crashed"
  defp describe_stop(other), do: inspect(other)

  defp form_label(key), do: Map.get(@form_labels, key, key)

  # Stored in the order the reader thinks in rather than whatever order the map
  # happens to iterate in.
  defp sorted_forms(%Word{forms: forms}) when is_map(forms) do
    Word.form_keys()
    |> Enum.filter(&Map.has_key?(forms, &1))
    |> Enum.map(&{&1, forms[&1]})
  end

  defp sorted_forms(_word), do: []

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-baseline justify-between mb-2">
          <h1 class="text-3xl font-bold">Dictionary</h1>
          <form phx-change="select-pair">
            <select
              name="language_pair"
              class="border border-gray-300 rounded-lg px-3 py-1 text-sm bg-white text-gray-900"
            >
              <option :for={pair <- @language_pairs} value={pair} selected={pair == @language_pair}>
                {pair}
              </option>
            </select>
          </form>
        </div>

        <p class="text-gray-600 mb-8">
          Inflected forms are generated rather than written by hand, and are not shown
          on any page until you approve them here.
        </p>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
          <div class="bg-white text-gray-900 p-4 rounded-lg shadow-md">
            <div class="text-2xl font-bold text-amber-600">{@stats.pending}</div>
            <div class="text-gray-600 text-sm mt-1">Waiting</div>
          </div>
          <div class="bg-white text-gray-900 p-4 rounded-lg shadow-md">
            <div class="text-2xl font-bold text-emerald-600">{@stats.approved}</div>
            <div class="text-gray-600 text-sm mt-1">Approved</div>
          </div>
          <div class="bg-white text-gray-900 p-4 rounded-lg shadow-md">
            <div class="text-2xl font-bold text-red-600">{@stats.rejected}</div>
            <div class="text-gray-600 text-sm mt-1">Rejected</div>
          </div>
          <div class="bg-white text-gray-900 p-4 rounded-lg shadow-md">
            <div class="text-2xl font-bold text-gray-500">{@stats.ungenerated}</div>
            <div class="text-gray-600 text-sm mt-1">Not generated</div>
          </div>
        </div>

        <div class="bg-white text-gray-900 p-6 rounded-lg shadow-md mb-8">
          <h2 class="text-xl font-semibold mb-4">Generate</h2>

          <div
            :if={!@configured? && @run.status in [:idle, :finished]}
            class="text-sm text-amber-700 bg-amber-50 p-3 rounded-lg"
          >
            No API key is configured. Set <code>ANTHROPIC_API_KEY</code>
            in <code>.env</code>
            and restart the app.
          </div>

          <div :if={@run.status == :running} class="space-y-3">
            <div class="flex items-baseline justify-between">
              <span class="text-gray-700">
                Generating {@run.language_pair} — {@run.done} of {@run.total}
              </span>
              <button
                phx-click="cancel"
                class="text-sm text-red-600 hover:text-red-700 hover:underline"
              >
                Stop after this batch
              </button>
            </div>
            <div class="h-2 w-full bg-gray-100 rounded-full overflow-hidden">
              <div
                class="h-full bg-emerald-500 rounded-full transition-all duration-500"
                style={"width: #{progress_percent(@run)}%"}
              >
              </div>
            </div>
          </div>

          <div :if={@run.status == :cancelling} class="text-sm text-gray-600">
            Stopping after the batch in flight — it is already paid for, so its results are kept.
          </div>

          <div :if={@configured? && @run.status in [:idle, :finished]}>
            <div :if={@queued == 0} class="text-gray-600">
              Every {@language_pair} entry has been generated. Import more words to add to the queue.
            </div>

            <div :if={@queued > 0} class="flex flex-wrap items-end gap-4">
              <form phx-change="select-count">
                <label class="block text-sm text-gray-600 mb-1">How many</label>
                <select
                  name="count"
                  class="border border-gray-300 rounded-lg px-3 py-2 bg-white text-gray-900"
                >
                  <option :for={choice <- @batch_choices} value={choice} selected={choice == @count}>
                    {min(choice, @queued)} entries
                  </option>
                </select>
              </form>

              <button
                phx-click="generate"
                data-confirm={"Generate #{will_generate(@count, @queued)} entries? This calls the API and costs about #{money(Run.estimate_cost(will_generate(@count, @queued)))}."}
                class="bg-emerald-500 text-white py-2 px-5 rounded-lg hover:bg-emerald-600 transition"
              >
                Generate {will_generate(@count, @queued)}
              </button>

              <span class="text-sm text-gray-500 pb-2">
                about {money(Run.estimate_cost(will_generate(@count, @queued)))}, {@queued} left to do
              </span>
            </div>
          </div>

          <div
            :if={@run.status == :finished && @run.language_pair}
            class="mt-4 pt-4 border-t border-gray-100 text-sm text-gray-600"
          >
            Last run: generated {@run.generated} {@run.language_pair} entries, cost {money(
              @run.spent_usd
            )}.
            <span :if={@run.failed != []} class="text-amber-700">
              {length(@run.failed)} could not be generated.
            </span>
            <span :if={@run.stopped} class="text-amber-700">
              Run {describe_stop(@run.stopped)}.
            </span>
          </div>
        </div>

        <div :if={@entries == []} class="bg-white text-gray-900 p-8 rounded-lg shadow-md text-center">
          <p class="text-gray-600">Nothing is waiting for review.</p>
          <p class="text-sm text-gray-500 mt-2">
            Generate some entries above and they will appear here.
          </p>
        </div>

        <div class="space-y-4">
          <div
            :for={entry <- @entries}
            id={"entry-#{entry.id}"}
            class="bg-white text-gray-900 p-6 rounded-lg shadow-md"
          >
            <div class="flex items-start justify-between gap-4">
              <div>
                <div class="flex items-baseline gap-3">
                  <span class="text-xl font-semibold">{entry.original_word}</span>
                  <span :if={entry.pos} class="text-xs uppercase tracking-wide text-gray-500">
                    {entry.pos}
                  </span>
                  <span :if={entry.frequency_rank} class="text-xs text-gray-400">
                    rank {entry.frequency_rank}
                  </span>
                </div>
                <div class="text-gray-600 mt-1">{entry.target_translation}</div>
              </div>

              <div class="flex gap-2 shrink-0">
                <button
                  phx-click="approve"
                  phx-value-id={entry.id}
                  class="bg-emerald-500 text-white py-2 px-4 rounded-lg hover:bg-emerald-600 transition"
                >
                  Approve
                </button>
                <button
                  phx-click="reject"
                  phx-value-id={entry.id}
                  class="bg-white text-red-600 border border-red-200 py-2 px-4 rounded-lg hover:bg-red-50 transition"
                >
                  Reject
                </button>
              </div>
            </div>

            <dl class="grid grid-cols-2 md:grid-cols-3 gap-3 mt-4 pt-4 border-t border-gray-100">
              <div :for={{key, value} <- sorted_forms(entry)}>
                <dt class="text-xs uppercase tracking-wide text-gray-500">{form_label(key)}</dt>
                <dd class="font-medium">{value}</dd>
              </div>
            </dl>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
