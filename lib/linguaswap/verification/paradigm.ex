defmodule Linguaswap.Verification.Paradigm do
  @moduledoc """
  Tier 1: is this surface in that lemma's paradigm, under a bundle we accept?

  The strongest evidence in the chain, because it is the only tier that is not
  an opinion. A morphological database says *corrió* is the third person
  singular preterite of *correr*; nothing about that answer depends on a model
  having a good day.

  ## Matched by containment

  A claim confirms if the surface appears anywhere in the lemma's paradigm
  under a bundle whose tags are all present in the row's — so Spanish `past`
  accepts both *corrió* and *corría*, because
  `Linguaswap.Languages.paradigm_features/1` lists no aspect for it. This is
  Phase 4's Decision 1 restated as a query: the client detects that English
  marked a past tense and has no way to choose between preterite and imperfect,
  so a verifier that demanded one would be rejecting forms the runtime is
  perfectly happy to serve.

  ## When it contradicts

  Only when it has the paradigm in front of it:

    * The lemma is absent from the table — `:unknown`. Most function words,
      every phrase, and every reflexive land here, and that is not evidence of
      anything.
    * The lemma is present and the surface appears under an accepted bundle —
      `:confirmed`.
    * The lemma is present, the table has rows for the part of speech being
      asked about, and the surface is not among them — `:contradicted`. Either
      the surface is not a form of that lemma at all, which is the invented-form
      case, or it is the wrong one: *correrá* is a real word and a real form of
      *correr*, and it is not a past tense.
    * The lemma is present only under a *different* part of speech — `:unknown`.
      See `same_category/2`; this case is not hypothetical.

  The last case is only fair because the paradigm file carries every row for the
  slots the form keys ask about — every third person singular indicative, every
  participle, every converb, every noun plural (see
  `priv/data/build_verification_data.py`). A file filtered more narrowly than
  the questions asked of it would turn absence into a false contradiction.

  Translation claims always return `:unknown`. Whether *correr* is the right
  Spanish for "run" is a lexical judgement, and a paradigm table holds no
  opinion on it — this is the boundary the chain does not cross, and pretending
  otherwise is how a verifier starts laundering guesses.
  """

  use Linguaswap.Verification.Verifier

  alias Linguaswap.Languages
  alias Linguaswap.Verification.Claim
  alias Linguaswap.Verification.Resource

  # UniMorph's part-of-speech tags, which are the first tag of every bundle the
  # feature map uses.
  @categories ~w(V N ADJ ADV)

  @impl true
  def tier, do: 1

  @impl true
  def name, do: "paradigm"

  @impl true
  def available?(language_pair) do
    language = Languages.target(language_pair)

    Resource.paradigms?(language) and Languages.paradigm_features(language_pair) != %{}
  end

  @impl true
  def verify(%Claim{} = claim, _opts) do
    with false <- Claim.translation?(claim),
         bundles when bundles != [] <- accepted_bundles(claim),
         rows when is_list(rows) <- lookup(claim),
         [_ | _] = rows <- same_category(rows, bundles) do
      if Enum.any?(rows, &matches?(&1, claim.surface, bundles)) do
        :confirmed
      else
        :contradicted
      end
    else
      _ -> :unknown
    end
  end

  # Rows for the part of speech the claim is about, and the reason a lemma being
  # present is not on its own enough to contradict.
  #
  # UniMorph's Spanish knows *querer* only as a noun — `querer`/`quereres`, the
  # nominalised infinitive — and carries no verb paradigm for it at all. Without
  # this filter the lemma is "known", every verb form is missing from it, and
  # the tier contradicts *quiere*, *quiso*, *queriendo* and *querido*: four
  # false contradictions on a correct entry for one of the commonest verbs in
  # the language. A resource that knows this lemma as a different part of speech
  # knows nothing about this claim, and the honest answer is `:unknown`.
  defp same_category(rows, bundles) do
    categories = bundles |> Enum.flat_map(&MapSet.to_list/1) |> Enum.filter(&(&1 in @categories))

    Enum.filter(rows, fn {_surface, tags} -> Enum.any?(categories, &MapSet.member?(tags, &1)) end)
  end

  defp accepted_bundles(%Claim{} = claim) do
    claim.language_pair
    |> Languages.paradigm_features()
    |> Map.get(claim.field, [])
    |> Enum.map(&MapSet.new/1)
  end

  # `nil` for a lemma the table has never heard of, which the caller reads as
  # `:unknown`. A lemma with rows but no matching surface is a different answer
  # and is not routed through here.
  defp lookup(%Claim{lemma: lemma, language_pair: pair}) when is_binary(lemma) do
    pair
    |> Languages.target()
    |> Resource.paradigms()
    |> Map.get(Resource.normalize(lemma))
  end

  defp lookup(_claim), do: nil

  defp matches?({surface, tags}, wanted, bundles) do
    surface == Resource.normalize(wanted) and Enum.any?(bundles, &MapSet.subset?(&1, tags))
  end
end
