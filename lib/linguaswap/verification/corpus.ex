defmodule Linguaswap.Verification.Corpus do
  @moduledoc """
  Tier 3: does this surface occur in the target language at all?

  The same `hermitdave/FrequencyWords` pipeline `build_dictionary.py` already
  uses for the English side, pointed at the target side — so this tier adds a
  data file, not a new kind of dependency, and it exists for roughly a hundred
  languages.

  ## What it can and cannot say

  It catches invented surfaces, which is a large share of the error class and
  the share a non-speaking reviewer would not catch either: a form that has
  never appeared in fifty thousand words of subtitles is a form to look at. It
  cannot confirm a *feature* — a frequency list has no idea that *corrió* is a
  past tense — so a confirmation here means only "this is a real word", and that
  is why it sits at tier 3 and why a language can refuse it by setting its
  confidence floor to 2.

  Absence never contradicts. Inflected forms live in the frequency tail, and a
  50,000-word list is not deep enough for an absence to mean anything; it is
  recorded as a flag on the claim (`attested?/2`) so the human queue can sort by
  it, and the claim falls to the next tier.

  ## Two claims it stays out of

  **Translations.** That 跑 is an attested Chinese word is nearly no evidence
  that it means "run", and letting existence approve a gloss is precisely the
  laundering Phase 4.5 exists to stop. Translation claims get `:unknown` here
  whatever the corpus says.

  **Phrases.** "se rindió" is two attested Spanish words in a row, and so is
  almost any pair of words. Confirming a multi-word surface from the attestation
  of its parts would approve reflexives and phrasal entries — the exact residue
  the roadmap reserves for the round trip or for a human — on evidence that is
  not really evidence at all.
  """

  use Linguaswap.Verification.Verifier

  alias Linguaswap.Languages
  alias Linguaswap.Verification.Claim
  alias Linguaswap.Verification.Resource

  @impl true
  def tier, do: 3

  @impl true
  def name, do: "corpus"

  @impl true
  def available?(language_pair) do
    language_pair |> Languages.target() |> Resource.corpus?()
  end

  @impl true
  def verify(%Claim{} = claim, _opts) do
    cond do
      Claim.translation?(claim) -> :unknown
      multi_word?(claim.surface) -> :unknown
      attested?(claim.language_pair, claim.surface) -> :confirmed
      true -> :unknown
    end
  end

  @doc """
  Whether a surface appears in the target language's frequency list.

  A multi-word surface is attested when every word in it is. That is too weak
  to confirm a claim on — see the module note — but it is the right shape for a
  flag, because a phrase containing an invented word is still worth flagging.

  Returns `nil` rather than `false` when the language has no corpus file, so a
  caller can tell "not attested" from "nothing to attest against".
  """
  def attested?(language_pair, surface) when is_binary(surface) do
    corpus = language_pair |> Languages.target() |> Resource.corpus()

    if MapSet.size(corpus) == 0 do
      nil
    else
      surface
      |> String.split(~r/\s+/u, trim: true)
      |> case do
        [] -> nil
        words -> Enum.all?(words, &MapSet.member?(corpus, Resource.normalize(&1)))
      end
    end
  end

  def attested?(_language_pair, _surface), do: nil

  defp multi_word?(surface) when is_binary(surface),
    do: String.contains?(String.trim(surface), " ")

  defp multi_word?(_surface), do: false
end
