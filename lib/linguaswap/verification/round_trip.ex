defmodule Linguaswap.Verification.RoundTrip do
  @moduledoc """
  Tier 4: analyse the generated surface cold and see whether it comes back.

  A model is handed the target-language surfaces on their own — no English, no
  expected feature, no mention of what they are supposed to be — and asked what
  they are: the base form they belong to, and what they mean. A claim confirms
  when the analysis arrives back at what generation was asked for.

  ## Why this is not an LLM judge

  A judge is shown an answer and asked whether it is correct, and it agrees,
  because agreeing is easy and because the answer under test is sitting right
  there anchoring it. This runs in the opposite direction. Nothing in the
  analysis prompt says what the surface should be, so a hallucinated form has
  nothing to be anchored to: *corrió* analyses back to *correr* and a past
  tense, and an invented *corrido…* something either analyses to a different
  lemma or is reported as unrecognised. Hallucinated morphology rarely analyses
  back to the lemma it came from — that asymmetry is the whole of the evidence
  here, and it is why the surfaces are batched away from their entries rather
  than sent alongside them.

  ## What it verifies that nothing else can

  Two things, both of which the local tiers are silent on by construction:

    * **Translations.** Tiers 1 to 3 verify morphology given a lemma and say
      nothing about whether the lemma is the right gloss. The round trip does:
      the analysis reports what the target word means, and the claim confirms
      when the English entry is among those meanings. For `en-zh` this is the
      only claim there is — Chinese does not inflect, so an entry is its
      translation — and it is why Chinese sits at a confidence floor of 4.
    * **Phrases and reflexives.** *rindiéndose* attaches a clitic to a gerund
      and appears in no plain paradigm table for *rendir*. An analysis has no
      such gap.

  ## What it costs

  One request per batch of surfaces, not one per claim — `prepare/2` does the
  work for the whole run and `verify/2` reads the answers. On the measured
  Phase 4 figures that is roughly the price of generating the same entries
  again, which is the honest cost of checking work rather than trusting it.

  ## Where its evidence is weakest

  A model that does not know a language will analyse confidently anyway, and in
  a low-resource pair the analysing model may share a training corpus, and
  therefore a blind spot, with the generating one. Agreement is only evidence
  when the errors are independent. That is a per-language judgement, so it is
  made in `Linguaswap.Languages` by the confidence floor rather than here: this
  module reports what the round trip said, and the floor decides whether that is
  allowed to approve anything.
  """

  use Linguaswap.Verification.Verifier

  alias Linguaswap.LLM
  alias Linguaswap.Languages
  alias Linguaswap.Verification.Claim
  alias Linguaswap.Vocabulary.Word

  require Logger

  # Surfaces per request. Smaller than generation's twenty: an analysis carries
  # more output per item — a lemma, features and a list of meanings — and a
  # dropped item here costs a verification rather than a whole entry.
  @batch_size 15

  # What the analysis may report a surface as. The same closed set the client
  # detects and `forms` is keyed by, so a reported feature can be compared with
  # the key that was asked for without a per-language translation table in
  # between. `base` is the dictionary form itself, which is what a translation
  # claim expects to hear.
  @features ["base" | Word.form_keys()]

  @impl true
  def tier, do: 4

  @impl true
  def name, do: "round_trip"

  @impl true
  def available?(_language_pair), do: LLM.configured?()

  @impl true
  def prepare(claims, opts) do
    analyses =
      claims
      |> Enum.reject(&(&1.surface in [nil, ""]))
      |> Enum.group_by(& &1.language_pair, & &1.surface)
      |> Enum.reduce(%{}, fn {language_pair, surfaces}, acc ->
        Map.merge(acc, analyse_all(language_pair, Enum.uniq(surfaces), opts))
      end)

    Keyword.put(opts, :analyses, analyses)
  end

  @impl true
  def verify(%Claim{} = claim, opts) do
    case opts
         |> Keyword.get(:analyses, %{})
         |> Map.get(key(claim.language_pair, claim.surface)) do
      nil -> :unknown
      analysis -> judge(claim, analysis)
    end
  end

  # A translation is confirmed by meaning and a form by morphology, and the two
  # are different questions asked of the same answer.
  defp judge(%Claim{} = claim, analysis) do
    if Claim.translation?(claim) do
      judge_meaning(claim, analysis)
    else
      judge_form(claim, analysis)
    end
  end

  defp judge_meaning(%Claim{} = claim, analysis) do
    wanted = normalize_english(claim.source_lemma || claim.source_word)
    meanings = analysis |> Map.get("meanings", []) |> Enum.map(&normalize_english/1)

    cond do
      wanted == "" -> :unknown
      meanings == [] -> :unknown
      Enum.any?(meanings, &meanings_agree?(&1, wanted)) -> :confirmed
      true -> :contradicted
    end
  end

  # A gloss and an entry rarely match as strings: "to run" against "run", "the
  # house" against "house". The comparison is therefore on content words, and a
  # reported meaning agrees when the entry is one of them — "give up" inside
  # "to give up on something" is agreement, and "walk" against "run" is not.
  defp meanings_agree?(meaning, wanted) do
    meaning == wanted or
      String.contains?(pad(meaning), pad(wanted)) or
      String.contains?(pad(wanted), pad(meaning))
  end

  defp pad(value), do: " " <> value <> " "

  defp judge_form(%Claim{} = claim, analysis) do
    lemma = normalize(Map.get(analysis, "lemma"))
    features = analysis |> Map.get("features", []) |> Enum.map(&normalize/1)

    cond do
      lemma == "" or features == [] -> :unknown
      not lemmas_agree?(lemma, normalize(claim.lemma)) -> :contradicted
      claim.field in features -> :confirmed
      true -> :contradicted
    end
  end

  # Reflexives are the case this exists for: generation stores "rendirse" as the
  # translation of "give up" and an analysis of "se rindió" may report either
  # "rendirse" or "rendir". Neither is wrong, so one containing the other counts
  # as the same lemma.
  defp lemmas_agree?(reported, wanted) do
    wanted != "" and
      (reported == wanted or String.starts_with?(reported, wanted) or
         String.starts_with?(wanted, reported))
  end

  defp analyse_all(language_pair, surfaces, opts) do
    surfaces
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce(%{}, fn batch, acc ->
      Map.merge(acc, analyse(language_pair, batch, opts))
    end)
  end

  defp analyse(language_pair, surfaces, opts) do
    case LLM.complete(prompt(language_pair, surfaces), response_schema(),
           system: system_prompt(language_pair),
           model: opts[:model],
           budget: opts[:budget]
         ) do
      {:ok, %{"entries" => entries}} when is_list(entries) ->
        for entry <- entries,
            is_map(entry),
            surface = entry["surface"],
            is_binary(surface),
            into: %{} do
          {key(language_pair, surface), entry}
        end

      {:ok, _unexpected} ->
        %{}

      {:error, reason} ->
        # A failed analysis leaves every claim in the batch at `:unknown`, which
        # routes them to a human. Verification failing closed is the only safe
        # direction: the alternative is approving on evidence never gathered.
        Logger.warning("Round-trip analysis failed for #{language_pair}: #{inspect(reason)}")
        %{}
    end
  end

  defp key(language_pair, surface), do: {language_pair, normalize(surface)}

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""

  # English glosses arrive with the noise a dictionary puts on them: an
  # infinitive marker, an article, a trailing note in brackets.
  defp normalize_english(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\([^)]*\)/u, " ")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.replace(~r/^(to|the|a|an)\s+/u, "")
  end

  defp normalize_english(_value), do: ""

  @doc """
  The system prompt for an analysis.

  Worded to the same rule as the generation prompts — see
  `Linguaswap.Dictionary.system_prompt/1` for why that matters — and, more
  importantly here, worded so that nothing in it says what any surface is
  supposed to be. The moment this prompt mentions the English entry, or the
  feature being checked, the tier stops being a round trip and becomes a judge
  agreeing with an answer it was shown.
  """
  def system_prompt(language_pair) do
    {source, target} = Languages.names(language_pair)

    """
    You are a #{target} lexicographer annotating a word list.

    For each #{target} form you are given, report its dictionary form, its part \
    of speech, what grammatical form it is, and its #{source} meanings.

    Rules:

    - Report what the form actually is. If a form is not #{target}, or you do \
      not recognise it, say so with an empty `features` list rather than \
      guessing at the nearest word.
    - `features` describes the given form relative to its dictionary form. Use \
      `base` when the form given *is* the dictionary form.
    - Describe the form in terms of the #{source} categories listed, choosing \
      every one that applies — a #{target} form that answers to more than one \
      #{source} category should list all of them.
    - `meanings` is up to three #{source} glosses, most common first, in the \
      plainest wording — a bare verb rather than an infinitive phrase.
    - A multi-word form is one item: give the dictionary form of the whole \
      expression.
    """
  end

  @doc """
  The user message listing the surfaces to analyse.

  A bare list, in no meaningful order, with nothing said about where any of them
  came from.
  """
  def prompt(language_pair, surfaces) do
    {source, target} = Languages.names(language_pair)

    """
    Annotate each #{target} form below. Return every one exactly once, spelled \
    as given, with its #{source} meanings.

    #{Enum.map_join(surfaces, "\n", &"- #{&1}")}
    """
  end

  @doc """
  JSON schema the analysis is pinned to.

  `features` is a list for the same reason `forms` is one in
  `Linguaswap.Dictionary.response_schema/0` — a uniform array survives
  constrained decoding where an object of optional keys does not — and because
  a form genuinely can answer to more than one English category at once.
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
              "surface" => %{
                "type" => "string",
                "description" => "The form exactly as it was given."
              },
              "lemma" => %{"type" => "string", "description" => "Its dictionary form."},
              "pos" => %{"type" => "string", "enum" => Word.parts_of_speech()},
              "features" => %{
                "type" => "array",
                "description" =>
                  "Every category the given form answers to; empty if unrecognised.",
                "items" => %{"type" => "string", "enum" => @features}
              },
              "meanings" => %{
                "type" => "array",
                "description" => "Up to three glosses, most common first.",
                "items" => %{"type" => "string"}
              }
            },
            "required" => ["surface", "lemma", "pos", "features", "meanings"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["entries"],
      "additionalProperties" => false
    }
  end
end
