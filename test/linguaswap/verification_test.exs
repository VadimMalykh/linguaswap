defmodule Linguaswap.VerificationTest do
  # Not async: the round-trip tier is configured through the application
  # environment, which is global.
  use Linguaswap.DataCase, async: false

  alias Linguaswap.LLM
  alias Linguaswap.Verification
  alias Linguaswap.Verification.Claim
  alias Linguaswap.Verification.Corpus
  alias Linguaswap.Verification.Paradigm
  alias Linguaswap.Verification.Rule
  alias Linguaswap.Vocabulary

  defp claim(attrs) do
    struct!(
      %Claim{
        field: "past",
        lemma: "correr",
        surface: "corrió",
        language_pair: "en-es",
        source_word: "run",
        source_lemma: "run",
        pos: "verb",
        word_id: System.unique_integer([:positive])
      },
      attrs
    )
  end

  defp word(attrs) do
    {:ok, word} =
      attrs
      |> Enum.into(%{
        original_word: "run",
        target_translation: "correr",
        language_pair: "en-es",
        frequency_rank: 1,
        pos: "verb",
        review_status: "pending",
        source: "import"
      })
      |> Vocabulary.create_word()

    word
  end

  # Answers every analysis request with the given entries.
  defp stub_analysis(entries) do
    previous = Application.get_env(:linguaswap, LLM, [])

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:analysis_prompt, Jason.decode!(body)})

      response = %{
        "content" => [%{"type" => "text", "text" => Jason.encode!(%{"entries" => entries})}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end

    Application.put_env(:linguaswap, LLM, api_key: "test-key", model: "claude-opus-5", plug: plug)
    on_exit(fn -> Application.put_env(:linguaswap, LLM, previous) end)
  end

  # Without a key the round trip is unavailable, so the chain is exactly its
  # three local tiers. Most tests want that: it is the free part, and it is what
  # runs on a machine that has never been given an API key.
  defp without_model do
    previous = Application.get_env(:linguaswap, LLM, [])
    Application.put_env(:linguaswap, LLM, api_key: nil)
    on_exit(fn -> Application.put_env(:linguaswap, LLM, previous) end)
  end

  describe "the paradigm tier" do
    test "confirms a form that is in the lemma's paradigm" do
      assert Paradigm.verify(claim(%{}), []) == :confirmed
    end

    test "accepts either aspect for a past tense" do
      # The containment match, and the reason it exists: the client detects that
      # English marked a past tense and has no way to choose between preterite
      # and imperfect, so a verifier must not demand one either.
      assert Paradigm.verify(claim(%{surface: "corrió"}), []) == :confirmed
      assert Paradigm.verify(claim(%{surface: "corría"}), []) == :confirmed
    end

    test "contradicts a real form of the lemma that is the wrong one" do
      # "correrá" is Spanish, and is a form of "correr". It is not a past tense.
      assert Paradigm.verify(claim(%{surface: "correrá"}), []) == :contradicted
    end

    test "contradicts a surface that is not a form of the lemma at all" do
      assert Paradigm.verify(claim(%{surface: "corrixó"}), []) == :contradicted
    end

    test "says nothing about a lemma it has never heard of" do
      assert Paradigm.verify(claim(%{lemma: "rendirse", surface: "se rindió"}), []) == :unknown
    end

    test "says nothing when it knows the lemma as another part of speech" do
      # UniMorph's Spanish carries "querer" only as a noun — the nominalised
      # infinitive — and has no verb paradigm for it. Reading that gap as a
      # contradiction produced four false contradictions on a correct entry the
      # first time this ran, which is what this asserts cannot come back.
      assert Paradigm.verify(
               claim(%{lemma: "querer", surface: "quiere", field: "third_person"}),
               []
             ) ==
               :unknown

      assert Paradigm.verify(claim(%{lemma: "querer", surface: "quiso"}), []) == :unknown
    end

    test "says nothing about a translation" do
      claim = claim(%{field: Claim.translation_field(), surface: "correr"})
      assert Paradigm.verify(claim, []) == :unknown
    end

    test "says nothing for a language with no paradigm file" do
      claim = claim(%{language_pair: "en-uz", lemma: "bo'lish", surface: "bo'ldi"})

      refute Paradigm.available?("en-uz")
      assert Paradigm.verify(claim, []) == :unknown
    end
  end

  describe "the rule tier" do
    defp plural(lemma, surface) do
      Rule.verify(
        claim(%{field: "plural", pos: "noun", lemma: lemma, surface: surface}),
        []
      )
    end

    test "confirms a regular Spanish plural" do
      assert plural("casa", "casas") == :confirmed
      assert plural("ciudad", "ciudades") == :confirmed
      assert plural("luz", "luces") == :confirmed
    end

    test "contradicts a plural formed the wrong way" do
      assert plural("casa", "casaes") == :contradicted
      assert plural("ciudad", "ciudads") == :contradicted
    end

    test "accepts an invariable plural" do
      assert plural("lunes", "lunes") == :confirmed
    end

    test "confirms a periphrastic comparative and its suppletives" do
      assert Rule.verify(
               claim(%{field: "comparative", lemma: "rápido", surface: "más rápido"}),
               []
             ) ==
               :confirmed

      assert Rule.verify(claim(%{field: "comparative", lemma: "bueno", surface: "mejor"}), []) ==
               :confirmed

      assert Rule.verify(
               claim(%{field: "superlative", lemma: "rápido", surface: "el más rápido"}),
               []
             ) == :confirmed
    end

    test "contradicts an invented synthetic comparative" do
      assert Rule.verify(
               claim(%{field: "comparative", lemma: "rápido", surface: "rapidísimo"}),
               []
             ) ==
               :contradicted
    end

    test "leaves phrases alone" do
      assert plural("a lot of", "muchos de") == :unknown
    end

    test "says nothing for a language with no rules" do
      refute Rule.available?("en-uz")

      assert Rule.verify(claim(%{language_pair: "en-uz", field: "plural", pos: "noun"}), []) ==
               :unknown
    end
  end

  describe "the corpus tier" do
    test "confirms an attested single-word surface" do
      assert Corpus.verify(claim(%{lemma: "querer", surface: "quiere"}), []) == :confirmed
    end

    test "says nothing about an unattested one, and never contradicts" do
      assert Corpus.verify(claim(%{surface: "corrixó"}), []) == :unknown
    end

    test "says nothing about a translation, however attested" do
      # That 跑 is a real Chinese word is nearly no evidence that it means "run",
      # and letting attestation approve a gloss is the laundering this whole
      # phase exists to stop.
      claim = claim(%{language_pair: "en-zh", field: Claim.translation_field(), surface: "跑"})

      assert Corpus.attested?("en-zh", "跑") == true
      assert Corpus.verify(claim, []) == :unknown
    end

    test "says nothing about a phrase, whose parts are always attested" do
      assert Corpus.verify(claim(%{lemma: "rendirse", surface: "se rindió"}), []) == :unknown
    end

    test "reports attestation as nil when the language has no corpus" do
      assert Corpus.attested?("en-uz", "bo'ldi") == nil
    end
  end

  describe "the chain" do
    test "the strongest tier with an opinion settles a claim" do
      without_model()

      # The paradigm knows this one, so the corpus is never reached even though
      # it would confirm too.
      entry = word(%{forms: %{"past" => "corrió"}})

      assert [{_word, decision}] = Verification.decide([entry])
      assert [%{verdict: :confirmed, tier: 1, verifier: "paradigm"}] = decision.evidence
    end

    test "falls through to a weaker tier when the stronger one has no data" do
      without_model()

      entry = word(%{target_translation: "querer", forms: %{"third_person" => "quiere"}})

      assert [{_word, decision}] = Verification.decide([entry])
      assert [%{verdict: :confirmed, tier: 3, verifier: "corpus"}] = decision.evidence
    end

    test "approves an entry whose every claim clears the language's floor" do
      without_model()

      entry = word(%{forms: %{"past" => "corrió", "gerund" => "corriendo"}})

      assert {:ok, updated} = verify_one(entry)
      assert updated.review_status == "approved"
      assert updated.verification["verdict"] == "confirmed"
      assert updated.verification["claims"]["past"]["verifier"] == "paradigm"
      assert updated.verified_at
    end

    test "drops a form a fact contradicts, and approves what is left" do
      without_model()

      # "correrá" is the future, not the past. Dropping it puts the entry back
      # to serving its base translation for a past tense, which is exactly what
      # an entry with no past form does — strictly better than serving a wrong
      # one, and no reader is needed to say so.
      entry = word(%{forms: %{"past" => "correrá", "gerund" => "corriendo"}})

      assert {:ok, updated} = verify_one(entry)
      assert updated.forms == %{"gerund" => "corriendo"}
      assert updated.review_status == "approved"
      assert updated.verification["dropped"] == ["past"]
    end

    test "queues an entry no tier could settle" do
      without_model()

      entry = word(%{target_translation: "rendirse", forms: %{"past" => "se rindió"}})

      assert {:ok, updated} = verify_one(entry)
      assert updated.review_status == "pending"
      assert updated.verification["verdict"] == "unknown"
      assert updated.verification["claims"]["past"]["verifier"] == nil
    end

    test "a pair with no resources and a strict floor approves nothing" do
      without_model()

      entry =
        word(%{
          language_pair: "en-uz",
          target_translation: "bo'lish",
          forms: %{"past" => "bo'ldi"}
        })

      assert Verification.availability("en-uz") == [
               {Verification.Paradigm, false},
               {Verification.Rule, false},
               {Verification.Corpus, false},
               {Verification.RoundTrip, false}
             ]

      assert {:ok, updated} = verify_one(entry)
      assert updated.review_status == "pending"
    end
  end

  describe "the round-trip tier" do
    test "confirms a translation that analyses back to the entry" do
      stub_analysis([
        %{
          "surface" => "跑",
          "lemma" => "跑",
          "pos" => "verb",
          "features" => ["base"],
          "meanings" => ["run", "to jog"]
        }
      ])

      entry =
        word(%{
          language_pair: "en-zh",
          target_translation: "跑",
          source: "llm",
          forms: %{}
        })

      assert {:ok, updated} = verify_one(entry)
      assert updated.review_status == "approved"
      assert updated.verification["claims"]["translation"]["verifier"] == "round_trip"
    end

    test "contradicts a translation that means something else" do
      stub_analysis([
        %{
          "surface" => "走",
          "lemma" => "走",
          "pos" => "verb",
          "features" => ["base"],
          "meanings" => ["walk", "leave"]
        }
      ])

      entry =
        word(%{language_pair: "en-zh", target_translation: "走", source: "llm", forms: %{}})

      assert {:ok, updated} = verify_one(entry)
      assert updated.review_status == "pending"
      assert updated.verification["claims"]["translation"]["verdict"] == "contradicted"
    end

    test "is never shown the answer it is checking" do
      stub_analysis([])

      entry =
        word(%{language_pair: "en-zh", target_translation: "跑", source: "llm", forms: %{}})

      verify_one(entry)

      assert_received {:analysis_prompt, request}
      %{"messages" => [%{"content" => message}], "system" => system} = request

      # The whole strength of this tier is that the analysis is cold. If the
      # English entry ever reaches the prompt, the tier has quietly become a
      # judge agreeing with an answer it was shown.
      #
      # Checked on word boundaries rather than as a substring: the schema names
      # every feature the analysis may report, and "gerund" contains "run".
      assert message =~ "跑"
      refute message =~ ~r/\brun\b/
      refute system =~ ~r/\brun\b/
    end

    test "is not asked about claims a local tier already settled" do
      stub_analysis([])

      # A paradigm confirms the past outright; only the reflexive phrase, which
      # no paradigm table carries, should cost an API call.
      settled = word(%{forms: %{"past" => "corrió"}})

      residue =
        word(%{
          original_word: "give up",
          target_translation: "rendirse",
          forms: %{"past" => "se rindió"}
        })

      Verification.decide([settled, residue])

      assert_received {:analysis_prompt, request}
      body = Jason.encode!(request)

      assert body =~ "se rindió"
      refute body =~ "corrió"
    end
  end

  describe "entries_needing_verification/2" do
    test "takes generated entries that have not been checked, in frequency order" do
      first = word(%{original_word: "run", frequency_rank: 5})
      second = word(%{original_word: "walk", frequency_rank: 1})
      _approved = word(%{original_word: "swim", review_status: "approved"})
      _ungenerated = word(%{original_word: "jump", review_status: nil})

      assert Verification.entries_needing_verification("en-es") |> Enum.map(& &1.id) ==
               [second.id, first.id]
    end

    test "does not come back for an entry the chain has already ruled on" do
      without_model()

      entry = word(%{forms: %{"past" => "corrió"}})
      verify_one(entry)

      assert Verification.entries_needing_verification("en-es") == []
    end
  end

  defp verify_one(entry) do
    [{word, decision}] = Verification.decide([entry])
    Verification.apply_decision(word, decision)
  end
end
