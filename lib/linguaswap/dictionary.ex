defmodule Linguaswap.Dictionary do
  @moduledoc """
  Generating and reviewing dictionary data.

  `Linguaswap.Vocabulary` owns what a *user* knows; this module owns what the
  *dictionary* knows, which until Phase 4 was whatever a human typed into a
  TSV. It fills the gaps with an LLM — part of speech and, above all, the
  target-side inflected forms in `words.forms` — and it owns the review state
  that decides whether generated data is ever served.

  ## What is generated, and what is not

  The generator never overwrites a translation that already exists. A rebuilt
  `en-es.tsv` is hand-checked data, and quietly replacing it with a model's
  second opinion is not something an import should do on its own; a missing
  translation is filled, an existing one is passed to the model as context so
  the forms it generates agree with it. Same for the lemma: filled when absent,
  respected when present.

  `pos` and `forms` are the actual product. They are what the client needs to
  put "era" on the page where it currently puts "ser".

  ## The shape of `forms`

  A form key names the *English* feature that asks for it — `past`, `gerund`,
  `plural` — because that is what the client detects on the page. The value is
  the complete target-side surface for the whole entry. For a phrase this means
  the whole phrase: "give up" carries `%{"past" => "se rindió"}`, not a head
  form the client would have to glue back onto a tail. English phrases inflect
  on their head and the tail is fixed, so the split is real, but it belongs at
  generation time where a model can see the whole phrase — the runtime stays
  dumb, which is the whole point of the precompute path (DESIGN Q1-E, Q4-A).

  ## Review

  Generated rows land as `pending` and are not served. A human approves or
  rejects them in the dashboard; only `approved` (and hand-authored `nil`) rows
  reach the extension. Rejection clears the generated forms and keeps the row
  out of the next generation pass, so a bad entry is not regenerated in a loop.
  """

  import Ecto.Query, warn: false

  alias Linguaswap.Repo
  alias Linguaswap.LLM
  alias Linguaswap.Vocabulary.Word

  # Entries per request. Small enough that one bad batch is cheap to lose and
  # the response stays well inside `max_tokens`, large enough that the fixed
  # cost of the instructions is amortised over real work.
  @batch_size 20

  @languages %{"en" => "English", "es" => "Spanish", "uz" => "Uzbek"}

  @doc """
  Human-readable language names for a pair, as `{source, target}`.
  """
  def language_names(language_pair) do
    [source, target] = String.split(language_pair, "-", parts: 2)
    {Map.get(@languages, source, source), Map.get(@languages, target, target)}
  end

  ## Selecting work

  @doc """
  Entries for a pair that have never been through generation.

  `review_status` is the marker: `nil` means untouched, so every seeded and
  imported row queues up exactly once, and a row that has been generated —
  whatever a human then decided about it — does not come back.
  """
  def entries_needing_generation(language_pair, limit \\ nil) do
    from(w in Word,
      where: w.language_pair == ^language_pair,
      where: is_nil(w.review_status),
      order_by: [asc_nulls_last: w.frequency_rank, asc: w.id]
    )
    |> maybe_limit(limit)
    |> Repo.all()
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: from(q in query, limit: ^limit)

  @doc """
  Generated entries waiting for a human, most useful word first.
  """
  def entries_pending_review(language_pair, limit \\ 50) do
    from(w in Word,
      where: w.language_pair == ^language_pair,
      where: w.review_status == "pending",
      order_by: [asc_nulls_last: w.frequency_rank, asc: w.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  How many entries sit in each review state for a pair.

  Hand-authored rows (`review_status` `nil`) are counted as `ungenerated`,
  which is what they are from this module's point of view.
  """
  def review_stats(language_pair) do
    counts =
      from(w in Word,
        where: w.language_pair == ^language_pair,
        group_by: w.review_status,
        select: {w.review_status, count(w.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      ungenerated: Map.get(counts, nil, 0),
      pending: Map.get(counts, "pending", 0),
      approved: Map.get(counts, "approved", 0),
      rejected: Map.get(counts, "rejected", 0)
    }
  end

  ## Review workflow

  @doc """
  Accepts a generated entry, so its forms start being served.
  """
  def approve(%Word{} = word) do
    word
    |> Word.changeset(%{review_status: "approved"})
    |> Repo.update()
  end

  @doc """
  Rejects a generated entry.

  The forms are cleared rather than kept out of sight: a rejected form is wrong,
  and leaving it in the row invites a later change to start serving it. The
  entry itself survives — its translation is still the dictionary's — and the
  `rejected` status keeps it out of the next generation pass.
  """
  def reject(%Word{} = word) do
    word
    |> Word.changeset(%{review_status: "rejected", forms: %{}})
    |> Repo.update()
  end

  @doc """
  Puts a rejected entry back in the generation queue.
  """
  def requeue(%Word{} = word) do
    word
    |> Ecto.Changeset.change(%{review_status: nil})
    |> Repo.update()
  end

  ## Generation

  @doc """
  Generates part of speech and inflected forms for a language pair.

  Walks the entries that have never been generated in frequency order — the
  most useful words first, so a run stopped by the cost cap has still bought
  something worth having — and writes each batch as it comes back. A batch that
  fails is reported and the run continues, unless the failure is one that will
  repeat for every batch (no API key, cost cap reached), in which case it stops.

  Options:

    * `:limit` — how many entries to attempt (default: all of them)
    * `:batch_size` — entries per request (default: #{@batch_size})
    * `:on_batch` — a function called with a `{done, total}` tuple after each
      batch, for progress reporting from a `mix` task

  Returns `%{generated: n, failed: [{original_word, reason}], stopped: reason
  | nil}`.
  """
  def generate(language_pair, opts \\ []) do
    entries = entries_needing_generation(language_pair, opts[:limit])
    batches = Enum.chunk_every(entries, opts[:batch_size] || @batch_size)
    total = length(entries)

    Enum.reduce_while(batches, %{generated: 0, failed: [], stopped: nil}, fn batch, acc ->
      case generate_batch(language_pair, batch, opts) do
        {:ok, applied, failed} ->
          acc = %{acc | generated: acc.generated + applied, failed: acc.failed ++ failed}
          if opts[:on_batch], do: opts[:on_batch].({acc.generated + length(acc.failed), total})
          {:cont, acc}

        {:error, reason} ->
          if fatal?(reason) do
            {:halt, %{acc | stopped: reason}}
          else
            failed = Enum.map(batch, &{&1.original_word, reason})
            {:cont, %{acc | failed: acc.failed ++ failed}}
          end
      end
    end)
  end

  # A missing key or an exhausted budget will not fix itself on the next batch,
  # so the run stops rather than burning through the dictionary collecting the
  # same error once per word.
  defp fatal?(:missing_api_key), do: true
  defp fatal?(:cost_cap_reached), do: true

  # Neither will a key the provider rejects. This is the mistyped-key case, and
  # without it a wrong key means one refused request per batch — 27 of them for
  # en-es — and a page of identical errors to read.
  defp fatal?({:status, status, _body}) when status in [401, 403], do: true

  defp fatal?(_reason), do: false

  @doc """
  Generates one batch of entries and writes what came back.

  Returns `{:ok, applied_count, failures}` or `{:error, reason}` when the
  request itself failed.
  """
  def generate_batch(language_pair, entries, opts \\ []) do
    case LLM.complete(prompt(language_pair, entries), response_schema(),
           system: system_prompt(language_pair),
           model: opts[:model],
           budget: opts[:budget]
         ) do
      {:ok, %{"entries" => generated}} when is_list(generated) ->
        {applied, failed} = apply_generated(entries, generated)
        {:ok, applied, failed}

      {:ok, _unexpected} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_generated(entries, generated) do
    by_word =
      generated
      |> Enum.filter(&is_map/1)
      |> Map.new(fn entry -> {String.downcase(to_string(entry["original_word"])), entry} end)

    Enum.reduce(entries, {0, []}, fn word, {applied, failed} ->
      case Map.get(by_word, String.downcase(word.original_word)) do
        nil ->
          {applied, failed ++ [{word.original_word, :not_returned}]}

        entry ->
          case update_from_generated(word, entry) do
            {:ok, _word} -> {applied + 1, failed}
            {:error, changeset} -> {applied, failed ++ [{word.original_word, changeset}]}
          end
      end
    end)
  end

  defp update_from_generated(%Word{} = word, entry) do
    forms = sanitize_forms(entry["forms"], entry["pos"])

    attrs = %{
      pos: entry["pos"],
      forms: forms,
      source: "llm",
      review_status: review_status_for(word, forms)
    }

    # The two fields the generator only ever fills in, never replaces. See the
    # module note: hand-authored data outranks a model's second opinion.
    attrs =
      fill_missing(attrs, :target_translation, word.target_translation, entry["translation"])

    attrs = fill_missing(attrs, :lemma, word.lemma, entry["lemma"])

    word
    |> Word.changeset(attrs)
    |> Repo.update()
  end

  # Review is for the target text a reader will see. An entry that came back
  # with no forms and no new translation proposes nothing to look at — a
  # pronoun or a preposition, generally — so it is approved on the spot rather
  # than filling the queue with rows whose only answer is "yes, fine".
  defp review_status_for(%Word{target_translation: translation}, forms) do
    has_translation = is_binary(translation) and String.trim(translation) != ""

    if forms == %{} and has_translation, do: "approved", else: "pending"
  end

  defp fill_missing(attrs, key, current, generated) do
    cond do
      is_binary(current) and String.trim(current) != "" -> attrs
      is_binary(generated) and String.trim(generated) != "" -> Map.put(attrs, key, generated)
      true -> attrs
    end
  end

  @doc """
  Keeps only the form keys that are real and that the part of speech can use.

  A model asked for verb forms will occasionally offer a plural anyway, and a
  form that repeats the base translation is noise the client would pay to send
  and then ignore — the fallback already covers it.
  """
  def sanitize_forms(forms, pos) when is_map(forms) do
    allowed = forms_for_pos(pos)

    forms
    |> Enum.filter(fn {key, value} ->
      key in allowed and is_binary(value) and String.trim(value) != ""
    end)
    |> Map.new(fn {key, value} -> {key, String.trim(value)} end)
  end

  def sanitize_forms(_forms, _pos), do: %{}

  @doc """
  Form keys that make sense for a part of speech.

  English is the side being detected, so this is English grammar: only a verb
  has a past tense, only a noun takes the plural reading of "-s", and only
  adjectives and adverbs compare. Anything else — a pronoun, a preposition —
  has no inflected forms worth storing.
  """
  def forms_for_pos("verb"), do: ~w(third_person past past_participle gerund)
  def forms_for_pos("noun"), do: ~w(plural)
  def forms_for_pos(pos) when pos in ~w(adjective adverb), do: ~w(comparative superlative)
  def forms_for_pos(_pos), do: []

  ## Prompting

  @doc """
  The system prompt for a language pair.
  """
  def system_prompt(language_pair) do
    {source, target} = language_names(language_pair)

    """
    You are a lexicographer building a #{source}-to-#{target} dictionary for a \
    language-learning browser extension. The extension replaces #{source} words \
    on a web page with their #{target} equivalents, in place, leaving the rest \
    of the sentence in #{source}.

    That is what the inflected forms are for. When the page says "she was \
    running", the extension has an entry for the #{source} base form and needs \
    the #{target} surface that belongs in that slot — not the dictionary form. \
    Give the form a #{target} speaker would actually write there.

    Rules:

    - Forms are keyed by the #{source} feature that triggers them, and the value \
      is the complete #{target} text that replaces the #{source} word.
    - A multi-word entry inflects as a unit: return the whole phrase in each \
      form, not just its head.
    - Verbs: use third person singular for `third_person` and `past`, since \
      that is the reading the extension cannot see the subject of. Prefer the \
      form most common in everyday writing.
    - Omit a form when #{target} does not mark that distinction, or when it \
      would be identical to the base translation. Do not invent a form to fill \
      a slot.
    - Keep the register neutral and the forms consistent with the translation \
      you are given.
    """
  end

  @doc """
  The user message describing one batch of entries.
  """
  def prompt(language_pair, entries) do
    {source, target} = language_names(language_pair)

    lines =
      Enum.map_join(entries, "\n", fn word ->
        translation =
          if is_binary(word.target_translation) and word.target_translation != "" do
            " (current #{target} translation: #{word.target_translation})"
          else
            " (no translation yet — provide one)"
          end

        "- #{word.original_word}#{translation}"
      end)

    """
    For each #{source} entry below, return its part of speech, its #{source} \
    base form, its #{target} translation, and the #{target} inflected forms the \
    extension can substitute.

    Where a current translation is given, keep it and make the forms agree with \
    it. Return every entry exactly once, spelled as given.

    #{lines}
    """
  end

  @doc """
  JSON schema the model's reply is pinned to.
  """
  def response_schema do
    form_properties =
      Map.new(Word.form_keys(), fn key -> {key, %{"type" => "string"}} end)

    %{
      "type" => "object",
      "properties" => %{
        "entries" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "original_word" => %{
                "type" => "string",
                "description" => "The entry exactly as it was given."
              },
              "lemma" => %{
                "type" => "string",
                "description" => "Its base form in the source language."
              },
              "pos" => %{"type" => "string", "enum" => Word.parts_of_speech()},
              "translation" => %{"type" => "string"},
              "forms" => %{
                "type" => "object",
                "properties" => form_properties,
                "additionalProperties" => false
              }
            },
            "required" => ["original_word", "lemma", "pos", "translation", "forms"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["entries"],
      "additionalProperties" => false
    }
  end
end
