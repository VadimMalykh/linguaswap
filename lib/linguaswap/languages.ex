defmodule Linguaswap.Languages do
  @moduledoc """
  Everything the app knows about a target language, in one table.

  Phase 4.5 needs three things per language that are declarations rather than
  code: a paradigm resource, a feature map from the English form keys to that
  resource's own feature bundles, and a confidence floor saying which tier of
  evidence is good enough to approve an entry here without a human. Keeping
  them together — next to the language's name, script and romanisation — is
  what makes adding a language a table entry instead of a fork in the pipeline.

  ## The feature map

  `paradigm_features/1` is the per-language artefact that actually encodes a
  linguistic decision. It answers, for each English form key, which UniMorph
  feature bundles count as an acceptable answer, and it is matched by
  **containment**: a surface confirms if it appears anywhere in the lemma's
  paradigm under a bundle whose tags are all present.

  Spanish `past` is the case that explains the shape. It lists no aspect, so
  both `V;IND;PST;PFV;3;SG` (*corrió*) and `V;IND;PST;IPFV;3;SG` (*corría*)
  confirm. That is deliberate and it is Phase 4's Decision 1 restated as a
  query: the runtime is not allowed to choose between preterite and imperfect,
  so the verifier must not demand a choice either. Person and number *are*
  listed, because the generation prompt asks for a third person singular and a
  first person form in that slot is a real error rather than a valid variant.

  ## The confidence floor

  The floor is the weakest tier whose confirmation may auto-approve an entry
  here. Lower is stricter. It is the honesty valve: a language with good
  resources approves from evidence, and a language without them routes to a
  human instead of approving on evidence that is not there.

  The floors below were set from what the resources actually turned out to be,
  not from how well-known the language is:

    * **Spanish, floor 3.** UniMorph covers 34,567 paradigm rows over the
      frequency-common lemmas, and OpenSubtitles gives a 50,000-word attestation
      list. Morphology can be settled from data.
    * **Chinese, floor 4.** There is nothing for tiers 1 and 2 to check: Chinese
      does not inflect, so `forms` is empty for every entry and the only claim
      worth verifying is the translation itself. Attestation says the characters
      exist; only the round trip speaks to whether they mean the right thing.
    * **Uzbek, floor 2.** Not caution for its own sake — the resources are
      genuinely absent. `github.com/unimorph/uzb` is 1,277 rows over 16 noun
      lemmas, none of which appear in `priv/data/en-uz.tsv`, and
      FrequencyWords has no Uzbek list at all. With tiers 1 and 3 silent and no
      Uzbek rules written, a floor of 2 means en-uz auto-approves nothing and
      says so, which is the truthful answer until a speaker or a resource
      arrives. Raising it to 4 would let round-trip analysis approve the whole
      dictionary on the strength of one model's opinion, in the pair where that
      opinion is least likely to be independent of the one that generated it.
  """

  alias Linguaswap.Verification.Rule

  # A form key maps to a list of alternative bundles; a surface confirms if it
  # carries any one of them. Keys absent from a map are questions that language's
  # resource cannot answer — Spanish comparatives are periphrastic and simply do
  # not appear in a paradigm table, so they fall to the rule tier.
  @languages %{
    "en" => %{
      name: "English",
      script: :latin,
      romanization: nil,
      confidence_floor: 3,
      paradigm_features: %{},
      rules: nil
    },
    "es" => %{
      name: "Spanish",
      script: :latin,
      romanization: nil,
      confidence_floor: 3,
      paradigm_features: %{
        "third_person" => [~w(V IND PRS 3 SG)],
        "past" => [~w(V IND PST 3 SG)],
        "past_participle" => [~w(V V.PTCP PST MASC SG)],
        "gerund" => [~w(V V.CVB PRS)],
        "plural" => [~w(N PL)]
      },
      rules: Rule.Spanish
    },
    "uz" => %{
      name: "Uzbek",
      script: :latin,
      romanization: nil,
      confidence_floor: 2,
      paradigm_features: %{},
      rules: nil
    },
    "zh" => %{
      name: "Chinese",
      script: :han,
      romanization: :pinyin,
      confidence_floor: 4,
      paradigm_features: %{},
      rules: nil
    }
  }

  @default %{
    name: nil,
    script: :latin,
    romanization: nil,
    confidence_floor: 1,
    paradigm_features: %{},
    rules: nil
  }

  @doc """
  The declaration for a language code, or a conservative default.

  An unknown language gets floor 1 rather than a generous one: a pair nobody
  has declared has no resources by definition, and the safe reading of "we know
  nothing about this language" is that nothing auto-approves.
  """
  def get(code) when is_binary(code), do: Map.get(@languages, code, %{@default | name: code})

  @doc """
  Language codes with a declaration.
  """
  def known, do: Map.keys(@languages)

  @doc """
  The human-readable name of a language code.
  """
  def name(code), do: get(code).name || code

  @doc """
  Source and target codes of a language pair, as `{"en", "es"}`.
  """
  def split(language_pair) when is_binary(language_pair) do
    case String.split(language_pair, "-", parts: 2) do
      [source, target] -> {source, target}
      [source] -> {source, source}
    end
  end

  @doc """
  Human-readable language names for a pair, as `{source, target}`.
  """
  def names(language_pair) do
    {source, target} = split(language_pair)
    {name(source), name(target)}
  end

  @doc """
  The target language code of a pair.
  """
  def target(language_pair) do
    {_source, target} = split(language_pair)
    target
  end

  @doc """
  The romanisation scheme a target language needs, or `nil`.

  `nil` means the written form is already something a learner can pronounce, so
  there is nothing to store: repeating "correr" as its own pronunciation guide
  is a column of noise. `:pinyin` means the opposite — a reader who meets 跑 has
  no way to say it, and the gloss is only half a gloss without *pǎo*.
  """
  def romanization(language_pair) do
    language_pair |> target() |> get() |> Map.fetch!(:romanization)
  end

  @doc """
  Whether entries for this pair should carry a pronunciation.
  """
  def romanized?(language_pair), do: romanization(language_pair) != nil

  @doc """
  Feature bundles that confirm a form key in this pair's target language.
  """
  def paradigm_features(language_pair) do
    language_pair |> target() |> get() |> Map.fetch!(:paradigm_features)
  end

  @doc """
  The rule module for this pair's target language, or `nil`.
  """
  def rules(language_pair) do
    language_pair |> target() |> get() |> Map.fetch!(:rules)
  end

  @doc """
  The weakest verification tier that may auto-approve an entry in this pair.
  """
  def confidence_floor(language_pair) do
    language_pair |> target() |> get() |> Map.fetch!(:confidence_floor)
  end
end
