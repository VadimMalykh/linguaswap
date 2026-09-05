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
      batch, for progress reporting from a `mix` task or a LiveView
    * `:should_continue` — a function called before each batch; returning
      anything but `true` ends the run cleanly. This is what a Stop button
      pulls on, and it is checked *between* batches rather than inside one so
      a request that has already been paid for is never thrown away

  Returns `%{generated: n, failed: [{original_word, reason}], stopped: reason
  | nil}`.
  """
  def generate(language_pair, opts \\ []) do
    entries = entries_needing_generation(language_pair, opts[:limit])
    batches = Enum.chunk_every(entries, opts[:batch_size] || @batch_size)
    total = length(entries)

    Enum.reduce_while(batches, %{generated: 0, failed: [], stopped: nil}, fn batch, acc ->
      if continue?(opts[:should_continue]) do
        run_batch(language_pair, batch, opts, acc, total)
      else
        {:halt, %{acc | stopped: :cancelled}}
      end
    end)
  end

  defp continue?(nil), do: true
  defp continue?(fun) when is_function(fun, 0), do: fun.() == true

  defp run_batch(language_pair, batch, opts, acc, total) do
    case generate_batch(language_pair, batch, opts) do
      {:ok, 0, failed} when acc.generated == 0 ->
        # Nothing in the first batch worked. Whatever is wrong — a prompt the
        # model declines, a schema it cannot satisfy — is wrong for every batch,
        # and finding that out 27 requests later costs money for no information.
        # This is the case that let a bad run bill for a whole dictionary before
        # anyone read the output.
        {:halt, %{acc | failed: acc.failed ++ failed, stopped: :first_batch_failed}}

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

  # A 400 is a malformed request — an unsupported parameter, a schema the API
  # rejects. The next batch is built the same way, so it fails the same way.
  defp fatal?({:status, 400, _body}), do: true

  defp fatal?(_reason), do: false

  # How many times a batch will go back for the entries the model left out. Two
  # is enough in practice: a model that drops entries drops a different set each
  # time, so a second and third look between them cover almost everything.
  @retries 2

  @doc """
  Generates a batch, going back for whatever the model left out.

  Dropped entries are the characteristic failure of this workload — a request
  for twenty comes back with sixteen, or with two, and which ones vary run to
  run. Rather than pick a model that happens to drop fewer, the missing entries
  are simply asked for again in a smaller batch, which is both more reliable
  than model choice and cheap: the retry only carries the entries that are
  actually missing.

  Returns `{:ok, applied_count, failures}` or `{:error, reason}` when a request
  itself failed.
  """
  def generate_batch(language_pair, entries, opts \\ []) do
    generate_with_retries(language_pair, entries, opts, opts[:retries] || @retries, 0)
  end

  defp generate_with_retries(language_pair, entries, opts, retries_left, applied_so_far) do
    case generate_once(language_pair, entries, opts) do
      {:ok, applied, failed} ->
        applied = applied + applied_so_far
        missing = for {word, :not_returned} <- failed, do: word

        cond do
          missing == [] or retries_left == 0 ->
            {:ok, applied, failed}

          true ->
            # Only the entries that came back short, and the other failures are
            # kept: a changeset error will not be fixed by asking again.
            other_failures = Enum.reject(failed, &match?({_word, :not_returned}, &1))
            retry_entries = Enum.filter(entries, &(&1.original_word in missing))

            case generate_with_retries(
                   language_pair,
                   retry_entries,
                   opts,
                   retries_left - 1,
                   applied
                 ) do
              {:ok, total, retry_failures} -> {:ok, total, other_failures ++ retry_failures}
              # A failed retry loses only what the retry was carrying.
              {:error, _reason} -> {:ok, applied, failed}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_once(language_pair, entries, opts) do
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
  def sanitize_forms(forms, pos) when is_list(forms) do
    forms
    |> Enum.flat_map(fn
      %{"feature" => feature, "value" => value} -> [{feature, value}]
      _ -> []
    end)
    |> sanitize_pairs(pos)
  end

  # The object shape the schema used to ask for. Kept so a provider that
  # answers with it — or a stored reply from before the schema changed — is
  # still understood.
  def sanitize_forms(forms, pos) when is_map(forms), do: sanitize_pairs(forms, pos)

  def sanitize_forms(_forms, _pos), do: %{}

  defp sanitize_pairs(pairs, pos) do
    allowed = forms_for_pos(pos)

    pairs
    |> Enum.filter(fn {key, value} ->
      key in allowed and is_binary(value) and String.trim(value) != ""
    end)
    |> Map.new(fn {key, value} -> {key, String.trim(value)} end)
  end

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

  ## Why this is worded the way it is

  The first version of this prompt explained the product: a browser extension
  that replaces words on a web page, in place. Claude's safety classifiers read
  that as a description of page-injection tooling and declined the request
  outright — `stop_reason: "refusal"`, category `cyber`, reproducibly, on a
  batch of words like "you", "the" and "a".

  So the framing here is the linguistics one — interlinear glossing, which is
  genuinely what this data is for — and nothing describes modifying a web page.
  The task is identical and the output is the same; only the explanation of
  *why* changed. If you edit this prompt, keep it that way, and see
  `Linguaswap.LLM.Provider.Anthropic` for the fallback that catches a refusal
  when one gets through anyway.
  """
  def system_prompt(language_pair) do
    {source, target} = language_names(language_pair)

    """
    You are a lexicographer compiling an #{source}-to-#{target} learner's \
    dictionary.

    Each entry needs its part of speech and the #{target} surface forms \
    corresponding to the common #{source} inflections. The dictionary is used \
    for interlinear glossing: a reader who meets "was running" is shown the \
    #{target} form that belongs in that slot rather than the bare dictionary \
    form, so the gloss reads naturally alongside the #{source}.

    Rules:

    - A form is keyed by the #{source} feature that calls for it, and its value \
      is the complete #{target} wording for that form.
    - A multi-word entry inflects as a unit: give the whole phrase in each \
      form, not just its head.
    - Verbs: use third person singular for `third_person` and `past`. The \
      subject is not known, so prefer the reading most common in everyday \
      writing.
    - Omit a form when #{target} does not mark that distinction, or when it \
      would be identical to the base translation. Do not invent a form to fill \
      a slot.
    - Keep the register neutral and the forms consistent with the translation \
      you are given.
    """
  end

  @doc """
  The user message describing one batch of entries.

  Worded to the same rule as `system_prompt/1`: it describes the lexicography,
  never the extension. An earlier version asked for "the forms the extension can
  substitute", and that phrase alone was enough to keep the refusals coming
  after the system prompt had been rewritten.
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
    For each #{source} entry below, give its part of speech, its #{source} base \
    form, its #{target} translation, and its #{target} inflected forms.

    Where a current translation is given, keep it and make the forms agree with \
    it. Return every entry exactly once, spelled as given.

    #{lines}
    """
  end

  @doc """
  JSON schema the model's reply is pinned to.

  ## Why `forms` is a list and not an object

  The obvious shape is an object with the seven form keys as optional
  properties. It is also the shape that broke: every model tried on it —
  Opus 5 at low effort, Opus 4.8, Sonnet 5 — sooner or later emitted the
  object with `'` instead of `"`, which collapses the whole thing into one
  string. A real reply read:

      "forms": {"third_person": "se rinde','past':'se rindió','gerund':'..."}

  Valid JSON, entirely wrong, and it would have sailed through review as a
  plausible-looking `third_person`. Constrained decoding is evidently much
  happier generating a uniform array of `{feature, value}` records than an
  object whose keys are each individually optional. With the array, the same
  models returned the same data with no corruption at all, and with the verb
  forms filled in properly rather than one key each.

  `sanitize_forms/2` turns the list back into the map the database stores, so
  the shape on the wire is the only thing that changed.
  """
  def response_schema do
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
                "type" => "array",
                "description" => "One record per inflected form that applies. Omit the rest.",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "feature" => %{"type" => "string", "enum" => Word.form_keys()},
                    "value" => %{"type" => "string"}
                  },
                  "required" => ["feature", "value"],
                  "additionalProperties" => false
                }
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
