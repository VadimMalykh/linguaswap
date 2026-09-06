defmodule Linguaswap.Verification.Verifier do
  @moduledoc """
  The contract every source of evidence implements.

  ## Three values, not two

  `verify/2` returns `:confirmed`, `:contradicted` or `:unknown`, and the third
  one is what makes this a chain rather than a switch. A verifier with no data
  for a claim says `:unknown` and the claim falls to the next tier, which is a
  completely different statement from `:contradicted` — "I have no opinion"
  against "I have an opinion and it is no".

  Collapsing the two into a boolean is the mistake that would force a
  per-language rewrite: a paradigm table that has never heard of a lemma would
  start rejecting perfectly good forms, and every language without a resource
  would need its own escape hatch. Most verifiers return `:unknown` most of the
  time. That is the normal case, not a failure.

  ## What a claim is

  A claim is one checkable statement about one field of one entry:

      %Linguaswap.Verification.Claim{
        field: "past",              # a form key, or "translation"
        lemma: "correr",            # the target-side lemma it should belong to
        surface: "corrió",          # what generation produced
        source_word: "run",         # the English entry, for the round trip back
        pos: "verb",
        language_pair: "en-es"
      }

  The roadmap's `verify(lemma, surface, feature, opts)` is this struct with its
  arguments named rather than positional — the four values are all still there,
  and putting them in a struct is what lets a verifier see the English side,
  which the round trip needs and a paradigm lookup ignores.

  ## Preparing a batch

  `prepare/2` exists for one verifier: the round trip costs an API call, and a
  call per claim would be several hundred requests for a dictionary. It is
  given every claim the chain is about to ask about and returns opts that
  `verify/2` then reads, so a tier that needs to do its work in bulk can, while
  a tier that reads a local table ignores it entirely. The default
  implementation returns the opts unchanged.

  ## Tiers

  `tier/0` is the strength of the evidence, 1 being strongest. It is what a
  language's confidence floor is compared against, so a verifier's tier is a
  claim about how much a confirmation from it is worth — not about the order it
  happens to run in.
  """

  alias Linguaswap.Verification.Claim

  @type verdict :: :confirmed | :contradicted | :unknown

  @doc "How strong this verifier's evidence is; 1 is strongest."
  @callback tier() :: pos_integer()

  @doc "A short name, stored on the entry as the reason it was approved."
  @callback name() :: String.t()

  @doc """
  Whether this verifier has anything to say about a language pair at all.

  Checked before a run so the UI can report which tiers are live for a pair
  rather than showing a chain of verifiers that will all return `:unknown`.
  """
  @callback available?(language_pair :: String.t()) :: boolean()

  @doc "Bulk work for a batch of claims; returns opts `verify/2` will read."
  @callback prepare(claims :: [Claim.t()], opts :: keyword()) :: keyword()

  @doc "The verdict on one claim."
  @callback verify(claim :: Claim.t(), opts :: keyword()) :: verdict()

  @optional_callbacks prepare: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour Linguaswap.Verification.Verifier

      @impl true
      def prepare(_claims, opts), do: opts

      defoverridable prepare: 2
    end
  end
end
