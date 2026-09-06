defmodule Linguaswap.Verification.Claim do
  @moduledoc """
  One checkable statement about one field of a dictionary entry.

  An entry is not verified as a whole, because it is not right or wrong as a
  whole: "give up → rendirse" can be a good translation carrying one bad past
  tense, and an approval that cannot tell those apart is the rubber stamp Phase
  4.5 exists to remove. So the unit is a claim, and an entry's verdict is
  assembled from its claims in `Linguaswap.Verification`.

  Two kinds of claim come out of an entry:

    * **`"translation"`** — the target side means the English entry. Only made
      when the generator supplied the translation; a translation that came from
      a hand-authored TSV is not the model's guess to check, and re-verifying it
      would be checking the dictionary against a model rather than the other
      way round.
    * **a form key** — `past`, `plural` and the rest: this surface is that form
      of that lemma.

  The distinction matters to the verifiers. A paradigm table has an opinion
  about a form and none whatsoever about whether a gloss is apt; the round trip
  is the reverse way round for translations. `translation?/1` is how a verifier
  says which question it is being asked.
  """

  @enforce_keys [:field, :lemma, :surface, :language_pair]
  defstruct [
    :field,
    :lemma,
    :surface,
    :language_pair,
    :source_word,
    :source_lemma,
    :pos,
    :word_id
  ]

  @type t :: %__MODULE__{
          field: String.t(),
          lemma: String.t() | nil,
          surface: String.t(),
          language_pair: String.t(),
          source_word: String.t() | nil,
          source_lemma: String.t() | nil,
          pos: String.t() | nil,
          word_id: integer() | nil
        }

  @translation "translation"

  @doc """
  The field name a translation claim carries.
  """
  def translation_field, do: @translation

  @doc """
  Whether the claim is about the gloss rather than about a form.
  """
  def translation?(%__MODULE__{field: @translation}), do: true
  def translation?(%__MODULE__{}), do: false
end
