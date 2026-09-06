defmodule Linguaswap.Verification.Rule do
  @moduledoc """
  Tier 2: a small per-language rule, for the places the rule is genuinely closed.

  This tier exists because two of the four inflecting parts of speech are
  settled in Spanish by rules a paradigm table either does not carry or does not
  need to. Noun plurals are almost entirely regular, and comparatives are
  periphrastic — *más rápido*, with four suppletive exceptions — so UniMorph has
  no comparative row to look up at all and would leave every adjective in the
  dictionary at `:unknown`.

  It is tier 2 rather than tier 1 because a rule is a generalisation and a
  paradigm row is a fact. Where both speak, the paradigm speaks first.

  ## The line this tier must not cross

  A rule belongs here only when a competent speaker would call an exception to
  it an error rather than a variant. Spanish plural formation qualifies; Spanish
  verb morphology emphatically does not, and there is no verb rule module for
  exactly that reason — the irregulars are the common words, which is to say
  they are most of this dictionary. A rule that is right 80% of the time
  contradicts good forms 20% of the time, and a false contradiction is worse
  than a shrug: `:unknown` sends the entry to the next tier, `:contradicted`
  sends a correct form to a human as a suspected error.
  """

  alias Linguaswap.Languages
  alias Linguaswap.Verification.Claim

  use Linguaswap.Verification.Verifier

  @impl true
  def tier, do: 2

  @impl true
  def name, do: "rule"

  @impl true
  def available?(language_pair), do: Languages.rules(language_pair) != nil

  @impl true
  def verify(%Claim{} = claim, _opts) do
    case Languages.rules(claim.language_pair) do
      nil -> :unknown
      module -> module.check(claim)
    end
  end

  defmodule Spanish do
    @moduledoc """
    Spanish plural and comparative rules.

    Two dozen lines that settle two of the four inflecting parts of speech, and
    deliberately nothing else.

    ## Plurals

    A noun ending in an unstressed vowel takes `-s`; one ending in a consonant
    takes `-es`, with a final `z` becoming `ces`. That covers the language, and
    the cases it does not cover are cases where it declines to answer rather
    than guessing:

      * A word already ending in `-s` or `-x` and stressed on a non-final
        syllable is invariable (*el lunes*, *los lunes*), so a plural equal to
        the singular is accepted rather than contradicted.
      * Stressed final vowels (*el sofá* → *los sofás* / *sofaes*) admit both
        endings in usage, so both pass.

    ## Comparatives

    Spanish forms the comparative with *más*, apart from four suppletives —
    *mejor*, *peor*, *mayor*, *menor*. So a comparative confirms if it is *más*
    plus the base translation, or one of those four; anything else is a form the
    language does not make this way. The superlative adds a determiner in front
    of the same shape (*el más rápido*), which the check allows for.
    """

    alias Linguaswap.Verification.Claim
    alias Linguaswap.Verification.Resource

    @suppletive_comparatives ~w(mejor peor mayor menor)

    @vowels ~w(a e i o u)

    @doc """
    The verdict this rule set reaches on a claim, `:unknown` for anything it has
    no rule about.
    """
    def check(%Claim{} = claim) do
      surface = Resource.normalize(claim.surface)
      lemma = Resource.normalize(claim.lemma)

      cond do
        Claim.translation?(claim) -> :unknown
        surface == "" or lemma == "" -> :unknown
        claim.field == "plural" and claim.pos == "noun" -> plural(lemma, surface)
        claim.field in ~w(comparative superlative) -> comparative(claim.field, lemma, surface)
        true -> :unknown
      end
    end

    # Multi-word entries are left alone: "a lot of" pluralises somewhere inside
    # the phrase, not at its end, and this rule reads the end.
    defp plural(lemma, surface) do
      cond do
        String.contains?(lemma, " ") -> :unknown
        surface == lemma and invariable?(lemma) -> :confirmed
        surface in plurals(lemma) -> :confirmed
        true -> :contradicted
      end
    end

    defp plurals(lemma) do
      last = String.last(lemma)

      cond do
        last == "z" -> [String.slice(lemma, 0..-2//1) <> "ces"]
        # A stressed final vowel takes either ending in practice.
        last in ~w(á é í ó ú) -> [lemma <> "s", lemma <> "es"]
        last in @vowels -> [lemma <> "s"]
        true -> [lemma <> "es"]
      end
    end

    # *el lunes* / *los lunes*, *el tórax* / *los tórax*: no written accent on
    # the final syllable and an -s or -x ending means the plural is the singular.
    defp invariable?(lemma) do
      String.ends_with?(lemma, ["s", "x"]) and not String.contains?(lemma, ~w(á é í ó ú))
    end

    defp comparative(field, lemma, surface) do
      cond do
        String.contains?(lemma, " ") -> :unknown
        surface in @suppletive_comparatives -> :confirmed
        periphrastic?(field, lemma, surface) -> :confirmed
        true -> :contradicted
      end
    end

    # "más rápido" for the comparative; the superlative adds a determiner in
    # front, and which one depends on the noun it modifies, so any of them pass.
    defp periphrastic?("comparative", lemma, surface), do: surface == "más " <> lemma

    defp periphrastic?("superlative", lemma, surface) do
      Enum.any?(["", "el ", "la ", "los ", "las ", "lo "], &(surface == &1 <> "más " <> lemma))
    end
  end
end
