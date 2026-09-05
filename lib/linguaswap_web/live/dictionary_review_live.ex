defmodule LinguaswapWeb.DictionaryReviewLive do
  @moduledoc """
  The review queue for generated dictionary data (Phase 4).

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
  alias Linguaswap.Repo
  alias Linguaswap.Vocabulary
  alias Linguaswap.Vocabulary.Word

  @page_size 25

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
    language_pair = Vocabulary.language_pair_for_target(user.target_language)

    {:ok, socket |> assign(language_pair: language_pair) |> load_queue()}
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

    assign(socket,
      entries: Dictionary.entries_pending_review(language_pair, @page_size),
      stats: Dictionary.review_stats(language_pair)
    )
  end

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
          <h1 class="text-3xl font-bold">Review Generated Forms</h1>
          <span class="text-sm text-gray-500">{@language_pair}</span>
        </div>

        <p class="text-gray-600 mb-8">
          These inflected forms were generated rather than written by hand. They are
          not shown on any page until you approve them.
        </p>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
          <div class="bg-white p-4 rounded-lg shadow-md">
            <div class="text-2xl font-bold text-amber-600">{@stats.pending}</div>
            <div class="text-gray-600 text-sm mt-1">Waiting</div>
          </div>
          <div class="bg-white p-4 rounded-lg shadow-md">
            <div class="text-2xl font-bold text-emerald-600">{@stats.approved}</div>
            <div class="text-gray-600 text-sm mt-1">Approved</div>
          </div>
          <div class="bg-white p-4 rounded-lg shadow-md">
            <div class="text-2xl font-bold text-red-600">{@stats.rejected}</div>
            <div class="text-gray-600 text-sm mt-1">Rejected</div>
          </div>
          <div class="bg-white p-4 rounded-lg shadow-md">
            <div class="text-2xl font-bold text-gray-500">{@stats.ungenerated}</div>
            <div class="text-gray-600 text-sm mt-1">Not generated</div>
          </div>
        </div>

        <div :if={@entries == []} class="bg-white p-8 rounded-lg shadow-md text-center">
          <p class="text-gray-600">Nothing is waiting for review.</p>
          <p class="text-sm text-gray-500 mt-2">
            Run <code class="bg-gray-100 px-1 rounded">mix linguaswap.import_words</code>
            with <code class="bg-gray-100 px-1 rounded">--generate</code>
            to fill in more entries.
          </p>
        </div>

        <div class="space-y-4">
          <div
            :for={entry <- @entries}
            id={"entry-#{entry.id}"}
            class="bg-white p-6 rounded-lg shadow-md"
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
