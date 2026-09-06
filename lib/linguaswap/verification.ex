defmodule Linguaswap.Verification do
  @moduledoc """
  Approving generated dictionary data from evidence rather than from a reader.

  Phase 4 shipped a generator and a gate. The generator works. The gate — a
  human approving every row before its forms are served — does not, for a
  reason worse than slowness: **the reviewer cannot answer the question.**
  Per-entry approval assumes someone who reads the target language, this project
  does not have one, and a gate that always returns "approved" is not a gate. It
  is a delay that launders unverified data into the database wearing an
  `approved` label a later reader will trust.

  So the queue survives and what reaches it shrinks. An entry is broken into
  claims (`Linguaswap.Verification.Claim`), each claim is put to a chain of
  verifiers strongest first, and the entry is approved without a human when
  every claim was confirmed by evidence the language's confidence floor accepts.

  ## The chain

  | Tier | Verifier | What it knows |
  | --- | --- | --- |
  | 1 | `Paradigm` | A morphological database, matched by containment |
  | 2 | `Rule` | A small closed per-language rule |
  | 3 | `Corpus` | Whether the surface occurs in the language at all |
  | 4 | `RoundTrip` | What a model analyses the surface as, shown no answer |

  Each verifier returns `:confirmed`, `:contradicted` or `:unknown`, and the
  first one with an opinion settles the claim. `:unknown` is the normal answer —
  most verifiers have nothing to say about most claims — and it is emphatically
  not `:contradicted`.

  There is no tier 5. Cross-model consensus was specified as the weakest tier
  and is not built, because tiers 1 to 4 turned out to leave a residue that is
  lexical rather than morphological, and a second model generating the same
  entry is a second opinion on exactly the judgement two models are most likely
  to share a blind spot about.

  ## What is decided without a human

    * **Approved** — every claim confirmed, and the weakest tier that did any
      confirming is at or above the language's floor.
    * **A contradicted form is dropped** when the contradiction came from tier 1
      or 2, and the entry is then judged on what is left. Dropping a form
      restores exactly the behaviour of an entry that never had one: the client
      falls back to the base translation. It is safe in a way that overwriting
      a translation would not be, and a paradigm row saying *correrá* is not a
      past tense is not a judgement call.
    * **Everything else goes to the queue** — a contradiction from the round
      trip, a contradicted translation, and every claim the chain returned
      `:unknown` for. That residue is lexical and phrasal, which is the part a
      non-expert can settle with a dictionary open.

  Nothing here ever rejects an entry on its own. A rejection clears data, and
  the evidence that is good enough to withhold something from a page is not the
  same as the evidence that is good enough to delete it.
  """

  import Ecto.Query, warn: false

  alias Linguaswap.Languages
  alias Linguaswap.Repo
  alias Linguaswap.Verification.Claim
  alias Linguaswap.Verification.Corpus
  alias Linguaswap.Verification.Paradigm
  alias Linguaswap.Verification.Resource
  alias Linguaswap.Verification.RoundTrip
  alias Linguaswap.Verification.Rule
  alias Linguaswap.Vocabulary.Word

  require Logger

  @chain [Paradigm, Rule, Corpus, RoundTrip]

  # Entries per verification pass. The local tiers do not care, but the round
  # trip pays per request, and a pass that writes as it goes keeps whatever a
  # cancelled or capped run had already established.
  @batch_size 20

  # A contradiction from these tiers is a fact or a closed rule, so the form it
  # names is dropped rather than queued. A contradiction from a later tier is an
  # opinion, however well constructed, and opinions go to the queue.
  @self_correcting_tiers [1, 2]

  @doc """
  The verifiers in the chain, strongest first.
  """
  def chain, do: @chain

  @doc """
  Which tiers have data or a key for a language pair, as `[{module, boolean}]`.

  What makes the confidence floor legible in the dashboard: a floor of 3 means
  nothing if tiers 1 to 3 are all dark, and for `en-uz` they are.
  """
  def availability(language_pair) do
    Enum.map(@chain, &{&1, &1.available?(language_pair)})
  end

  ## Selecting work

  @doc """
  Generated entries that have not been through the chain, most useful first.
  """
  def entries_needing_verification(language_pair, limit \\ nil) do
    from(w in Word,
      where: w.language_pair == ^language_pair,
      where: w.review_status == "pending",
      where: is_nil(w.verified_at),
      order_by: [asc_nulls_last: w.frequency_rank, asc: w.id]
    )
    |> maybe_limit(limit)
    |> Repo.all()
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: from(q in query, limit: ^limit)

  @doc """
  How the chain has ruled on a pair so far.

  `unverified` counts entries still waiting for the chain; `queued` counts the
  ones it has been through and handed to a human anyway, which is the number
  that says whether this is working.
  """
  def stats(language_pair) do
    rows =
      from(w in Word,
        where: w.language_pair == ^language_pair,
        where: w.review_status == "pending" or not is_nil(w.verified_at),
        select:
          {w.review_status, not is_nil(w.verified_at), fragment("?->>'verdict'", w.verification)}
      )
      |> Repo.all()

    Enum.reduce(rows, %{unverified: 0, approved: 0, contradicted: 0, unknown: 0}, fn
      {"pending", false, _verdict}, acc ->
        %{acc | unverified: acc.unverified + 1}

      {_status, true, "confirmed"}, acc ->
        %{acc | approved: acc.approved + 1}

      {_status, true, "contradicted"}, acc ->
        %{acc | contradicted: acc.contradicted + 1}

      {_status, true, _verdict}, acc ->
        %{acc | unknown: acc.unknown + 1}

      {_status, _verified, _verdict}, acc ->
        acc
    end)
  end

  @doc """
  Rows whose target column repeats the English, most useful word first.

  A pre-pass rather than a tier, because it is not about the generated data at
  all — it is about the dictionary underneath it. `priv/data/en-uz.tsv` carries
  rows like `the -> the` where the English was never replaced, and verifying an
  inflected form on top of a translation that was never made is polishing the
  wrong layer. Worth running before paying to generate a pair.

  It reports rather than decides, because the same shape is sometimes correct:
  `en-es.tsv` has nine rows where the Spanish genuinely is the English word —
  *no*, *real*, *idea*, *hospital* — and a check that cannot tell those from
  `the -> the` has no business changing anything on its own.
  """
  def untranslated_rows(language_pair) do
    from(w in Word,
      where: w.language_pair == ^language_pair,
      where: not is_nil(w.target_translation),
      where: fragment("lower(?) = lower(?)", w.target_translation, w.original_word),
      order_by: [asc_nulls_last: w.frequency_rank, asc: w.id]
    )
    |> Repo.all()
  end

  ## Running the chain

  @doc """
  Runs the chain over the entries of a pair that have not been verified.

  Options mirror `Linguaswap.Dictionary.generate/2`, because the two are the
  same kind of job and are driven by the same button:

    * `:limit` — how many entries to attempt (default: all of them)
    * `:batch_size` — entries per pass (default: #{@batch_size})
    * `:on_batch` — called with `{done, total}` after each batch
    * `:should_continue` — called before each batch; anything but `true` ends
      the run cleanly
    * `:budget` — the budget the round trip is charged to

  Returns `%{verified: n, approved: n, queued: n, dropped: [...], stopped:
  reason | nil}`.
  """
  def verify(language_pair, opts \\ []) do
    entries = entries_needing_verification(language_pair, opts[:limit])
    total = length(entries)
    batches = Enum.chunk_every(entries, opts[:batch_size] || @batch_size)

    Enum.reduce_while(
      batches,
      %{verified: 0, approved: 0, queued: 0, dropped: [], stopped: nil},
      fn batch, acc ->
        if continue?(opts[:should_continue]) do
          acc = verify_batch(batch, opts, acc)
          if opts[:on_batch], do: opts[:on_batch].({acc.verified, total})
          {:cont, acc}
        else
          {:halt, %{acc | stopped: :cancelled}}
        end
      end
    )
  end

  defp continue?(nil), do: true
  defp continue?(fun) when is_function(fun, 0), do: fun.() == true

  defp verify_batch(entries, opts, acc) do
    entries
    |> decide(opts)
    |> Enum.reduce(acc, fn {word, decision}, acc ->
      case apply_decision(word, decision) do
        {:ok, _word} ->
          %{
            acc
            | verified: acc.verified + 1,
              approved: acc.approved + if(decision.verdict == :confirmed, do: 1, else: 0),
              queued: acc.queued + if(decision.verdict == :confirmed, do: 0, else: 1),
              dropped: acc.dropped ++ Enum.map(decision.dropped, &{word.original_word, &1})
          }

        {:error, changeset} ->
          Logger.error(
            "Could not record verification for #{word.original_word}: #{inspect(changeset.errors)}"
          )

          acc
      end
    end)
  end

  @doc """
  Decides a batch of entries without writing anything.

  Public because it is the honest way to look at what the chain would do —
  `mix run` over the dictionary, or a test — without a database write or an
  approval.
  """
  def decide(entries, opts \\ []) do
    verdicts = entries |> Enum.flat_map(&claims_for/1) |> settle(opts)

    Enum.map(entries, fn word -> {word, decide_entry(word, verdicts)} end)
  end

  # The chain is walked a tier at a time rather than a claim at a time, and each
  # tier only ever sees the claims still open when it is reached.
  #
  # That ordering is not a detail. `RoundTrip.prepare/2` bills an API request
  # for every surface it is handed, so preparing the whole chain up front — the
  # obvious shape — would pay a model to analyse the forms a paradigm table had
  # already settled for free. Walking tier by tier means the expensive tier is
  # asked about the residue and nothing else, which for `en-es` is a small
  # fraction of the run.
  defp settle(claims, opts) do
    open = Map.new(claims, &{claim_key(&1), {&1, base_evidence(&1)}})

    {settled, _opts} =
      Enum.reduce(@chain, {open, opts}, fn verifier, {claims, opts} ->
        case for {key, {claim, %{verdict: :unknown}}} <- claims,
                 verifier.available?(claim.language_pair),
                 do: {key, claim} do
          [] ->
            {claims, opts}

          pending ->
            opts = prepare(verifier, Enum.map(pending, &elem(&1, 1)), opts)
            {apply_verifier(verifier, pending, claims, opts), opts}
        end
      end)

    Map.new(settled, fn {key, {_claim, evidence}} -> {key, evidence} end)
  end

  defp prepare(verifier, claims, opts) do
    if function_exported?(verifier, :prepare, 2), do: verifier.prepare(claims, opts), else: opts
  end

  defp apply_verifier(verifier, pending, claims, opts) do
    Enum.reduce(pending, claims, fn {key, claim}, acc ->
      case verifier.verify(claim, opts) do
        :unknown ->
          acc

        verdict ->
          Map.update!(acc, key, fn {claim, evidence} ->
            {claim,
             %{evidence | verdict: verdict, tier: verifier.tier(), verifier: verifier.name()}}
          end)
      end
    end)
  end

  defp base_evidence(%Claim{} = claim) do
    %{
      field: claim.field,
      surface: claim.surface,
      verdict: :unknown,
      tier: nil,
      verifier: nil,
      # Recorded even when some other tier settled the claim: "not attested" is
      # the single most useful thing to show a human about a form they cannot
      # read, and it is free once the corpus is loaded.
      attested: Corpus.attested?(claim.language_pair, claim.surface)
    }
  end

  @doc """
  The claims an entry makes, as `Linguaswap.Verification.Claim` structs.

  One per stored form, plus one for the translation when the generator supplied
  it. A translation that came from a hand-authored TSV makes no claim: it is the
  dictionary's own data, and checking it against a model would be running the
  comparison backwards.
  """
  def claims_for(%Word{} = word) do
    translation_claim(word) ++ form_claims(word)
  end

  defp translation_claim(%Word{} = word) do
    if generated_translation?(word) do
      [
        %Claim{
          field: Claim.translation_field(),
          lemma: word.target_translation,
          surface: word.target_translation,
          language_pair: word.language_pair,
          source_word: word.original_word,
          source_lemma: word.lemma,
          pos: word.pos,
          word_id: word.id
        }
      ]
    else
      []
    end
  end

  # `source` records where the *translation* came from, which is the only field
  # of an entry the generator will not overwrite. A row that came out of an
  # import with a translation keeps `import` however much else was generated for
  # it; a row the generator had to translate itself is marked `llm`.
  # `priv/data/en-zh.tsv` is the whole English dictionary in that second state,
  # and `en-es.tsv` is none of it.
  defp generated_translation?(%Word{} = word) do
    word.source == "llm" and is_binary(word.target_translation) and
      String.trim(word.target_translation) != ""
  end

  defp form_claims(%Word{forms: forms} = word) when is_map(forms) do
    for {field, surface} <- forms, is_binary(surface) do
      %Claim{
        field: field,
        lemma: word.target_translation,
        surface: surface,
        language_pair: word.language_pair,
        source_word: word.original_word,
        source_lemma: word.lemma,
        pos: word.pos,
        word_id: word.id
      }
    end
  end

  defp form_claims(_word), do: []

  defp claim_key(%Claim{} = claim), do: {claim.word_id, claim.field}

  ## Deciding an entry

  defp decide_entry(%Word{} = word, verdicts) do
    evidence =
      word
      |> claims_for()
      |> Enum.map(&Map.fetch!(verdicts, claim_key(&1)))

    {dropped, kept} = Enum.split_with(evidence, &droppable?/1)

    floor = Languages.confidence_floor(word.language_pair)
    verdict = entry_verdict(kept, dropped, floor)

    %{
      verdict: verdict,
      floor: floor,
      evidence: evidence,
      dropped: Enum.map(dropped, & &1.field),
      # The weakest evidence anything was approved on, which is the number the
      # floor is actually about.
      tier: kept |> Enum.map(& &1.tier) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
    }
  end

  # A contradicted form from a tier that deals in facts. The translation is
  # never droppable — there is nothing to fall back to.
  defp droppable?(%{verdict: :contradicted, tier: tier, field: field}) do
    tier in @self_correcting_tiers and field != Claim.translation_field()
  end

  defp droppable?(_evidence), do: false

  # An entry whose every claim was dropped is approved rather than queued. What
  # is left is an entry with no forms and a translation nobody has questioned,
  # which is the case Phase 4 already approves on the spot — sending it to a
  # human would be asking them to look at a row with nothing on it.
  defp entry_verdict([], [_ | _], _floor), do: :confirmed
  defp entry_verdict([], [], _floor), do: :unknown

  defp entry_verdict(evidence, _dropped, floor) do
    cond do
      Enum.any?(evidence, &(&1.verdict == :contradicted)) -> :contradicted
      Enum.any?(evidence, &(&1.verdict == :unknown)) -> :unknown
      Enum.all?(evidence, &(&1.tier <= floor)) -> :confirmed
      true -> :unknown
    end
  end

  ## Writing the result

  @doc """
  Records a decision on an entry, approving it when the evidence allows.

  The evidence is stored on the row rather than logged, because the row is where
  someone will later ask why this is being served.
  """
  def apply_decision(%Word{} = word, decision) do
    forms = Map.drop(word.forms || %{}, decision.dropped)

    attrs = %{
      forms: forms,
      verified_at: DateTime.utc_now(:second),
      verification: encode(decision),
      review_status: if(decision.verdict == :confirmed, do: "approved", else: word.review_status)
    }

    word
    |> Word.changeset(attrs)
    |> Repo.update()
  end

  defp encode(decision) do
    %{
      "verdict" => to_string(decision.verdict),
      "tier" => decision.tier,
      "floor" => decision.floor,
      "dropped" => decision.dropped,
      "claims" =>
        Map.new(decision.evidence, fn evidence ->
          {evidence.field,
           %{
             "verdict" => to_string(evidence.verdict),
             "tier" => evidence.tier,
             "verifier" => evidence.verifier,
             "surface" => evidence.surface,
             "attested" => evidence.attested
           }}
        end)
    }
  end

  @doc """
  Puts an entry back in front of the chain.

  For a run made after a data file was rebuilt or a floor was changed: the
  previous verdict was reached against resources that no longer describe what is
  on disk.
  """
  def requeue(%Word{} = word) do
    word
    |> Ecto.Changeset.change(%{verified_at: nil, verification: %{}})
    |> Repo.update()
  end

  @doc """
  Drops the cached resource files, so the next run reads them again.
  """
  defdelegate reset_resources(), to: Resource, as: :reset
end
