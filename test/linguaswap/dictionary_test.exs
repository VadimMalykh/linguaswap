defmodule Linguaswap.DictionaryTest do
  # Not async: generation is configured through the application environment,
  # which is global.
  use Linguaswap.DataCase, async: false

  alias Linguaswap.Dictionary
  alias Linguaswap.LLM
  alias Linguaswap.LLM.Budget
  alias Linguaswap.Repo
  alias Linguaswap.Vocabulary
  alias Linguaswap.Vocabulary.Word

  setup do
    {:ok, budget} =
      Budget.start_link(
        name: :"budget_#{:erlang.unique_integer([:positive])}",
        config: [requests_per_minute: 1000, cost_cap_usd: 100.0]
      )

    %{budget: budget}
  end

  defp word(attrs) do
    {:ok, word} =
      attrs
      |> Enum.into(%{
        original_word: "run",
        target_translation: "correr",
        language_pair: "en-es",
        frequency_rank: 1
      })
      |> Vocabulary.create_word()

    word
  end

  # Answers every request with the given entries, exactly as the API would.
  defp stub_generation(entries, opts \\ []) do
    previous = Application.get_env(:linguaswap, LLM, [])

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:prompt, Jason.decode!(body)})

      response = %{
        "content" => [%{"type" => "text", "text" => Jason.encode!(%{"entries" => entries})}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(opts[:status] || 200, Jason.encode!(response))
    end

    Application.put_env(:linguaswap, LLM, api_key: "test-key", model: "claude-opus-5", plug: plug)
    on_exit(fn -> Application.put_env(:linguaswap, LLM, previous) end)
  end

  defp generated(attrs) do
    Enum.into(attrs, %{
      "original_word" => "run",
      "lemma" => "run",
      "pos" => "verb",
      "translation" => "correr",
      "forms" => forms(%{"past" => "corrió", "gerund" => "corriendo"})
    })
  end

  # The wire shape: a list of {feature, value} records.
  defp forms(map), do: Enum.map(map, fn {k, v} -> %{"feature" => k, "value" => v} end)

  describe "generate/2" do
    test "fills in part of speech and forms, and queues them for review", %{budget: budget} do
      word(%{original_word: "run", target_translation: "correr"})
      stub_generation([generated(%{})])

      assert %{generated: 1, failed: [], stopped: nil} =
               Dictionary.generate("en-es", budget: budget)

      entry = Vocabulary.get_word_by_original("run", "en-es")
      assert entry.pos == "verb"
      assert entry.forms == %{"past" => "corrió", "gerund" => "corriendo"}
      assert entry.review_status == "pending"

      # `source` names where the *translation* came from, and this one came
      # from the seed. The generator filled in the forms around it and left the
      # provenance of the translation alone.
      assert entry.source == "seed"
    end

    test "marks the source llm when it supplied the translation itself",
         %{budget: budget} do
      word(%{original_word: "run", target_translation: nil, language_pair: "en-zh"})
      stub_generation([generated(%{"translation" => "跑", "forms" => []})])

      assert %{generated: 1} = Dictionary.generate("en-zh", budget: budget)

      entry = Vocabulary.get_word_by_original("run", "en-zh")
      assert entry.target_translation == "跑"
      assert entry.source == "llm"
      # A generated translation queues even with no forms: for en-zh the
      # translation is the whole entry, and there is nothing else to check.
      assert entry.review_status == "pending"
    end

    test "stores a pronunciation for Chinese and ignores one offered for Spanish",
         %{budget: budget} do
      word(%{original_word: "run", target_translation: nil, language_pair: "en-zh"})
      word(%{original_word: "walk", target_translation: "caminar", frequency_rank: 2})

      stub_generation([
        generated(%{
          "original_word" => "run",
          "translation" => "跑",
          "pronunciation" => "pǎo",
          "forms" => []
        }),
        generated(%{
          "original_word" => "walk",
          "translation" => "caminar",
          "pronunciation" => "kah-mee-NAR"
        })
      ])

      Dictionary.generate("en-zh", budget: budget)
      Dictionary.generate("en-es", budget: budget)

      assert Vocabulary.get_word_by_original("run", "en-zh").pronunciation == "pǎo"
      # Spanish has no romanisation, so there is no field to fill and an offered
      # one is dropped rather than stored.
      assert Vocabulary.get_word_by_original("walk", "en-es").pronunciation == nil
    end

    test "never overwrites a translation that was already there", %{budget: budget} do
      word(%{original_word: "run", target_translation: "correr"})
      stub_generation([generated(%{"translation" => "ejecutar"})])

      Dictionary.generate("en-es", budget: budget)

      # Hand-authored data outranks a model's second opinion.
      assert Vocabulary.get_word_by_original("run", "en-es").target_translation == "correr"
    end

    test "fills a translation that is missing", %{budget: budget} do
      # A row with no translation cannot be created through the changeset, which
      # requires one, so this is the shape a future harvest path would produce.
      entry = word(%{original_word: "run", target_translation: "correr"})

      Repo.update_all(Ecto.Query.from(w in Word, where: w.id == ^entry.id),
        set: [target_translation: ""]
      )

      stub_generation([generated(%{"translation" => "correr"})])
      Dictionary.generate("en-es", budget: budget)

      assert Vocabulary.get_word_by_original("run", "en-es").target_translation == "correr"
    end

    test "still understands the older object shape for forms", %{budget: budget} do
      word(%{original_word: "run", target_translation: "correr"})
      stub_generation([generated(%{"forms" => %{"past" => "corrió"}})])

      Dictionary.generate("en-es", budget: budget)

      assert Vocabulary.get_word_by_original("run", "en-es").forms == %{"past" => "corrió"}
    end

    test "drops forms that do not belong to the part of speech", %{budget: budget} do
      word(%{original_word: "wall", target_translation: "pared"})

      stub_generation([
        generated(%{
          "original_word" => "wall",
          "pos" => "noun",
          "translation" => "pared",
          # A noun has no past tense, whatever the model offers.
          "forms" => forms(%{"plural" => "paredes", "past" => "paredó"})
        })
      ])

      Dictionary.generate("en-es", budget: budget)

      assert Vocabulary.get_word_by_original("wall", "en-es").forms == %{"plural" => "paredes"}
    end

    test "approves an entry with nothing to review on the spot", %{budget: budget} do
      word(%{original_word: "the", target_translation: "el"})

      stub_generation([
        generated(%{
          "original_word" => "the",
          "pos" => "determiner",
          "translation" => "el",
          "forms" => []
        })
      ])

      Dictionary.generate("en-es", budget: budget)

      # No forms and no new translation is nothing for a human to look at.
      assert Vocabulary.get_word_by_original("the", "en-es").review_status == "approved"
    end

    test "reports an entry the model left out instead of losing it", %{budget: budget} do
      word(%{original_word: "run", target_translation: "correr"})
      word(%{original_word: "walk", target_translation: "caminar", frequency_rank: 2})

      stub_generation([generated(%{})])

      assert %{generated: 1, failed: [{"walk", :not_returned}]} =
               Dictionary.generate("en-es", budget: budget)

      assert Vocabulary.get_word_by_original("walk", "en-es").review_status == nil
    end

    test "goes back for the entries the model left out", %{budget: budget} do
      word(%{original_word: "run", target_translation: "correr", frequency_rank: 1})
      word(%{original_word: "walk", target_translation: "caminar", frequency_rank: 2})

      # First request returns one of the two; the retry carries only the one
      # that was missing, which is the behaviour being asserted.
      previous = Application.get_env(:linguaswap, LLM, [])
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        n = Agent.get_and_update(counter, &{&1, &1 + 1})
        prompt = body |> Jason.decode!() |> get_in(["messages", Access.at(0), "content"])
        send(self(), {:asked_for, n, prompt})

        entries =
          if n == 0,
            do: [generated(%{})],
            else: [generated(%{"original_word" => "walk", "translation" => "caminar"})]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "content" => [%{"type" => "text", "text" => Jason.encode!(%{"entries" => entries})}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
          })
        )
      end

      Application.put_env(:linguaswap, LLM, api_key: "k", model: "claude-opus-4-8", plug: plug)
      on_exit(fn -> Application.put_env(:linguaswap, LLM, previous) end)

      assert %{generated: 2, failed: []} = Dictionary.generate("en-es", budget: budget)

      assert_received {:asked_for, 0, first}
      assert first =~ "run"
      assert first =~ "walk"

      # The retry carries only what was missing, so it costs a fraction of the
      # first attempt rather than repeating it.
      assert_received {:asked_for, 1, second}
      assert second =~ "walk"
      refute second =~ "- run"
    end

    test "stops rather than repeating a failure that cannot improve", %{budget: budget} do
      for rank <- 1..5,
          do: word(%{original_word: "w#{rank}", target_translation: "x", frequency_rank: rank})

      previous = Application.get_env(:linguaswap, LLM, [])
      Application.put_env(:linguaswap, LLM, api_key: nil)
      on_exit(fn -> Application.put_env(:linguaswap, LLM, previous) end)

      assert %{generated: 0, stopped: :missing_api_key} =
               Dictionary.generate("en-es", batch_size: 1, budget: budget)
    end

    test "stops on a key the provider rejects", %{budget: budget} do
      for rank <- 1..5,
          do: word(%{original_word: "w#{rank}", target_translation: "x", frequency_rank: rank})

      previous = Application.get_env(:linguaswap, LLM, [])

      plug = fn conn ->
        send(self(), :attempted)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "invalid"}}))
      end

      Application.put_env(:linguaswap, LLM, api_key: "wrong", model: "claude-opus-5", plug: plug)
      on_exit(fn -> Application.put_env(:linguaswap, LLM, previous) end)

      assert %{generated: 0, stopped: {:status, 401, _}} =
               Dictionary.generate("en-es", batch_size: 1, budget: budget)

      # A mistyped key is not worth one refused request per batch.
      assert_received :attempted
      refute_received :attempted
    end

    test "works through the dictionary in frequency order", %{budget: budget} do
      word(%{original_word: "rare", target_translation: "raro", frequency_rank: 900})
      word(%{original_word: "run", target_translation: "correr", frequency_rank: 1})

      stub_generation([generated(%{})])
      Dictionary.generate("en-es", limit: 1, budget: budget)

      # The most useful word first, so a run cut short by the cost cap has still
      # bought something worth having.
      assert Vocabulary.get_word_by_original("run", "en-es").review_status == "pending"
      assert Vocabulary.get_word_by_original("rare", "en-es").review_status == nil
    end

    test "does not come back to an entry it has already generated", %{budget: budget} do
      word(%{original_word: "run", target_translation: "correr"})
      stub_generation([generated(%{})])

      Dictionary.generate("en-es", budget: budget)
      assert %{generated: 0} = Dictionary.generate("en-es", budget: budget)
    end

    test "asks for the whole phrase, and stores it that way", %{budget: budget} do
      word(%{original_word: "give up", target_translation: "rendirse"})

      stub_generation([
        generated(%{
          "original_word" => "give up",
          "pos" => "verb",
          "translation" => "rendirse",
          "forms" => forms(%{"past" => "se rindió"})
        })
      ])

      Dictionary.generate("en-es", budget: budget)

      entry = Vocabulary.get_word_by_original("give up", "en-es")
      assert entry.forms == %{"past" => "se rindió"}
      assert entry.token_count == 2

      assert_received {:prompt, body}
      assert body["messages"] |> hd() |> Map.get("content") =~ "give up"
    end
  end

  describe "re-importing over generated data" do
    test "leaves the generated columns alone", %{budget: budget} do
      word(%{original_word: "run", target_translation: "correr", frequency_rank: 1})
      stub_generation([generated(%{})])
      Dictionary.generate("en-es", budget: budget)

      # Exactly what `mix linguaswap.import_words` does for that row.
      {:ok, _} =
        Vocabulary.upsert_word(%{
          original_word: "run",
          target_translation: "correr",
          language_pair: "en-es",
          frequency_rank: 1,
          difficulty_score: 1,
          pos: nil,
          source: "import"
        })

      entry = Vocabulary.get_word_by_original("run", "en-es")

      # Re-running the importer is how generation is triggered, so it must not
      # undo the last run's work — or approving an entry and re-importing would
      # silently un-generate it.
      assert entry.pos == "verb"
      assert entry.forms == %{"past" => "corrió", "gerund" => "corriendo"}
      assert entry.review_status == "pending"
    end
  end

  describe "review" do
    test "approving an entry starts it being served" do
      entry =
        word(%{original_word: "run", target_translation: "correr"})
        |> Word.changeset(%{forms: %{"past" => "corrió"}, review_status: "pending"})
        |> Repo.update!()

      assert Word.servable_forms(entry) == %{}

      {:ok, approved} = Dictionary.approve(entry)
      assert Word.servable_forms(approved) == %{"past" => "corrió"}
    end

    test "rejecting an entry clears the forms and keeps the word" do
      entry =
        word(%{original_word: "run", target_translation: "correr"})
        |> Word.changeset(%{forms: %{"past" => "corriró"}, review_status: "pending"})
        |> Repo.update!()

      {:ok, rejected} = Dictionary.reject(entry)

      assert rejected.forms == %{}
      assert rejected.review_status == "rejected"
      assert rejected.target_translation == "correr"
    end

    test "a rejected entry is not generated for again", %{budget: budget} do
      entry = word(%{original_word: "run", target_translation: "correr"})
      {:ok, _} = Dictionary.reject(entry)

      stub_generation([generated(%{})])
      assert %{generated: 0} = Dictionary.generate("en-es", budget: budget)

      # Until someone puts it back in the queue by hand.
      {:ok, _} = Dictionary.requeue(Repo.reload(entry))
      assert %{generated: 1} = Dictionary.generate("en-es", budget: budget)
    end

    test "counts what is waiting, done and untouched" do
      word(%{original_word: "run", target_translation: "correr"})

      word(%{original_word: "walk", target_translation: "caminar", frequency_rank: 2})
      |> Word.changeset(%{review_status: "pending"})
      |> Repo.update!()

      word(%{original_word: "eat", target_translation: "comer", frequency_rank: 3})
      |> Word.changeset(%{review_status: "approved"})
      |> Repo.update!()

      assert %{ungenerated: 1, pending: 1, approved: 1, rejected: 0} =
               Dictionary.review_stats("en-es")
    end
  end

  describe "prompting" do
    test "names both languages" do
      assert Dictionary.language_names("en-es") == {"English", "Spanish"}
      assert Dictionary.language_names("en-uz") == {"English", "Uzbek"}

      system = Dictionary.system_prompt("en-uz")
      assert system =~ "English"
      assert system =~ "Uzbek"
    end

    test "asks for pinyin only where the script needs it" do
      chinese = Dictionary.system_prompt("en-zh")
      assert chinese =~ "Chinese"
      assert chinese =~ "Hanyu Pinyin"

      # A Spanish prompt is what it was before Chinese existed: "correr" is
      # already its own pronunciation guide, and a field nothing can fill is an
      # invitation to fill it anyway.
      refute Dictionary.system_prompt("en-es") =~ "Pinyin"

      refute Dictionary.response_schema("en-es")["properties"]["entries"]["items"]["properties"]
             |> Map.has_key?("pronunciation")

      assert Dictionary.response_schema("en-zh")["properties"]["entries"]["items"]["properties"]
             |> Map.has_key?("pronunciation")
    end

    test "gives the model the translation an entry already has" do
      prompt =
        Dictionary.prompt("en-es", [word(%{original_word: "run", target_translation: "correr"})])

      assert prompt =~ "- run (current Spanish translation: correr)"
    end

    test "pins the reply to the columns the importer writes" do
      schema = Dictionary.response_schema()
      item = schema["properties"]["entries"]["items"]

      assert item["required"] == ["original_word", "lemma", "pos", "translation", "forms"]
      assert item["properties"]["pos"]["enum"] == Word.parts_of_speech()

      # `forms` is a list of {feature, value} records, not an object with
      # optional keys — see the schema's own docs for the corruption that
      # shape caused.
      forms = item["properties"]["forms"]
      assert forms["type"] == "array"
      assert forms["items"]["properties"]["feature"]["enum"] == Word.form_keys()
      assert forms["items"]["required"] == ["feature", "value"]
    end
  end
end
