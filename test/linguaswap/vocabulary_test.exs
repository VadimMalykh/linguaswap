defmodule Linguaswap.VocabularyTest do
  use Linguaswap.DataCase

  alias Linguaswap.Vocabulary
  alias Linguaswap.AccountsFixtures

  describe "create_word/1" do
    test "creates a word with valid attributes" do
      attrs = %{
        original_word: "hello",
        target_translation: "hola",
        language_pair: "en-es",
        frequency_rank: 1,
        difficulty_score: 1
      }

      assert {:ok, word} = Vocabulary.create_word(attrs)
      assert word.original_word == "hello"
      assert word.target_translation == "hola"
      assert word.language_pair == "en-es"
    end

    test "returns error with missing required fields" do
      assert {:error, changeset} = Vocabulary.create_word(%{})
      assert errors_on(changeset).original_word
      assert errors_on(changeset).language_pair
    end

    # A dictionary entry may be a placeholder waiting for the generator to
    # supply its target side — priv/data/en-zh.tsv is 539 rows in exactly that
    # state — so a blank translation is legal until the row has been generated,
    # and stored as nil so blank has one spelling.
    test "accepts an entry with no translation yet" do
      assert {:ok, word} =
               Vocabulary.create_word(%{
                 original_word: "placeholder_#{System.unique_integer()}",
                 target_translation: "",
                 language_pair: "en-zh"
               })

      assert word.target_translation == nil
      refute Linguaswap.Vocabulary.Word.servable?(word)
    end

    test "requires a translation once the entry has been generated" do
      assert {:error, changeset} =
               Vocabulary.create_word(%{
                 original_word: "generated_#{System.unique_integer()}",
                 language_pair: "en-zh",
                 review_status: "pending"
               })

      assert errors_on(changeset).target_translation
    end

    test "returns error with duplicate original_word + language_pair" do
      attrs = %{
        original_word: "unique_dup_#{System.unique_integer()}",
        target_translation: "hola",
        language_pair: "en-es"
      }

      assert {:ok, _} = Vocabulary.create_word(attrs)
      assert {:error, changeset} = Vocabulary.create_word(attrs)
      assert errors_on(changeset).original_word
    end

    test "rejects generated data in a shape the client cannot use" do
      attrs = %{original_word: "run", target_translation: "correr", language_pair: "en-es"}

      # A key the client never asks for is dead weight, and a non-string value
      # would reach the page as "[object Object]".
      assert {:error, changeset} =
               Vocabulary.create_word(Map.put(attrs, :forms, %{"future" => "correrá"}))

      assert errors_on(changeset).forms

      assert {:error, changeset} = Vocabulary.create_word(Map.put(attrs, :forms, %{"past" => 42}))
      assert errors_on(changeset).forms

      # Part of speech decides how an English "-s" is read, so a free-form
      # label is no use.
      assert {:error, changeset} = Vocabulary.create_word(Map.put(attrs, :pos, "v."))
      assert errors_on(changeset).pos

      assert {:ok, word} =
               Vocabulary.create_word(
                 %{attrs | original_word: "run2"}
                 |> Map.merge(%{pos: "verb", forms: %{"past" => "corrió"}})
               )

      assert word.forms == %{"past" => "corrió"}
    end
  end

  describe "get_or_create_word!/3" do
    test "returns existing word if found" do
      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      found = Vocabulary.get_or_create_word!("hello", "hola", "en-es")
      assert found.id == word.id
    end

    test "creates word if not found" do
      found = Vocabulary.get_or_create_word!("hello", "hola", "en-es")
      assert found.original_word == "hello"
      assert found.target_translation == "hola"
    end
  end

  describe "get_word_by_original/2" do
    test "finds word by original_word and language_pair" do
      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      found = Vocabulary.get_word_by_original("hello", "en-es")
      assert found.id == word.id
    end

    test "returns nil for non-existent word" do
      assert Vocabulary.get_word_by_original("nonexistent", "en-es") == nil
    end
  end

  describe "get_word_by_original_or_lemma/2" do
    setup do
      {:ok, run} =
        Vocabulary.create_word(%{
          original_word: "run",
          target_translation: "correr",
          language_pair: "en-es",
          frequency_rank: 100
        })

      {:ok, running} =
        Vocabulary.create_word(%{
          original_word: "running",
          target_translation: "corriendo",
          language_pair: "en-es",
          lemma: "run",
          frequency_rank: 900
        })

      %{run: run, running: running}
    end

    test "finds a word by its own spelling", %{running: running} do
      assert Vocabulary.get_word_by_original_or_lemma("running", "en-es").id == running.id
    end

    test "falls back to the lemma when no spelling matches", %{run: run} do
      {:ok, walking} =
        Vocabulary.create_word(%{
          original_word: "walking",
          target_translation: "caminando",
          language_pair: "en-es",
          lemma: "walk"
        })

      assert Vocabulary.get_word_by_original_or_lemma("walk", "en-es").id == walking.id
      assert Vocabulary.get_word_by_original_or_lemma("run", "en-es").id == run.id
    end

    test "prefers an exact spelling over another entry sharing the lemma", %{run: run} do
      # "run" is both its own entry and the lemma of "running"; the spelling
      # must win even though the lemma matches too.
      assert Vocabulary.get_word_by_original_or_lemma("run", "en-es").id == run.id
    end

    test "is case-insensitive on the lemma" do
      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "Monday",
          target_translation: "lunes",
          language_pair: "en-es"
        })

      assert Vocabulary.get_word_by_original_or_lemma("Monday", "en-es").id == word.id
      assert Vocabulary.get_word_by_original_or_lemma("monday", "en-es").id == word.id
    end

    test "stays within the language pair" do
      {:ok, _} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "salom",
          language_pair: "en-uz"
        })

      assert Vocabulary.get_word_by_original_or_lemma("hello", "en-es") == nil
    end

    test "returns nil for an unknown word" do
      assert Vocabulary.get_word_by_original_or_lemma("nonexistent", "en-es") == nil
    end
  end

  describe "get_or_create_user_word!/2" do
    test "creates user_word for new combination with default hard status" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      user_word = Vocabulary.get_or_create_user_word!(user.id, word.id)
      assert user_word.user_id == user.id
      assert user_word.word_id == word.id
      assert user_word.reveal_count == 0
      assert user_word.status == "hard"
      assert user_word.exposure_count == 0
    end

    test "returns existing user_word if found" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      uw1 = Vocabulary.get_or_create_user_word!(user.id, word.id)
      uw2 = Vocabulary.get_or_create_user_word!(user.id, word.id)
      assert uw1.id == uw2.id
    end
  end

  describe "record_word_reveal/2" do
    test "increments reveal_count" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, uw} = Vocabulary.record_word_reveal(user.id, word.id)
      assert uw.reveal_count == 1
      assert uw.status == "hard"
      assert uw.last_revealed_at != nil

      {:ok, uw} = Vocabulary.record_word_reveal(user.id, word.id)
      assert uw.reveal_count == 2
    end

    test "demotes trivial to simple on reveal" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      Vocabulary.get_or_create_user_word!(user.id, word.id)
      Vocabulary.rate_word(user.id, word.id, "trivial")

      {:ok, uw} = Vocabulary.record_word_reveal(user.id, word.id)
      assert uw.status == "simple"
    end
  end

  describe "record_word_replacement/2" do
    test "increments replacement_count" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, uw} = Vocabulary.record_word_replacement(user.id, word.id)
      assert uw.replacement_count == 1

      {:ok, uw} = Vocabulary.record_word_replacement(user.id, word.id)
      assert uw.replacement_count == 2
    end
  end

  describe "rate_word/3" do
    test "sets status to hard" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, uw} = Vocabulary.rate_word(user.id, word.id, "hard")
      assert uw.status == "hard"
    end

    test "sets status to simple" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, uw} = Vocabulary.rate_word(user.id, word.id, "simple")
      assert uw.status == "simple"
    end

    test "sets status to trivial" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, uw} = Vocabulary.rate_word(user.id, word.id, "trivial")
      assert uw.status == "trivial"
    end

    test "rejects invalid status" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      Vocabulary.get_or_create_user_word!(user.id, word.id)

      assert {:error, :invalid_status} = Vocabulary.rate_word(user.id, word.id, "invalid")
    end
  end

  describe "prune_words/2" do
    defp dict_word(original, translation, rank) do
      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: original,
          target_translation: translation,
          language_pair: "en-es",
          frequency_rank: rank
        })

      word
    end

    test "removes entries a rebuilt list no longer carries" do
      keep = dict_word("hello", "hola", 1)
      stale = dict_word("begin", "empezar", 93)

      assert %{deleted: 1, retained: []} = Vocabulary.prune_words("en-es", ["hello"])

      assert Vocabulary.get_word_by_original("hello", "en-es").id == keep.id
      refute Vocabulary.get_word_by_original("begin", "en-es")
      refute Linguaswap.Repo.get(Linguaswap.Vocabulary.Word, stale.id)
    end

    test "never deletes an entry a user has progress on" do
      user = AccountsFixtures.user_fixture()
      dict_word("hello", "hola", 1)
      stale = dict_word("I", "yo", 10)

      Vocabulary.record_word_reveal(user.id, stale.id)

      # user_words cascades on delete, so pruning this row would take the
      # user's history with it. It is reported for a human instead.
      assert %{deleted: 0, retained: [retained]} = Vocabulary.prune_words("en-es", ["hello"])
      assert retained.id == stale.id
      assert Linguaswap.Repo.get(Linguaswap.Vocabulary.Word, stale.id)
      assert Vocabulary.get_user_word(user.id, stale.id)
    end

    test "leaves other language pairs alone" do
      {:ok, uz} =
        Vocabulary.create_word(%{
          original_word: "begin",
          target_translation: "boshlamoq",
          language_pair: "en-uz",
          frequency_rank: 93
        })

      dict_word("begin", "empezar", 93)

      assert %{deleted: 1} = Vocabulary.prune_words("en-es", [])
      assert Linguaswap.Repo.get(Linguaswap.Vocabulary.Word, uz.id)
    end

    test "is a no-op when the list still carries everything" do
      dict_word("hello", "hola", 1)
      dict_word("world", "mundo", 2)

      assert %{deleted: 0, retained: []} =
               Vocabulary.prune_words("en-es", ["hello", "world"])
    end
  end

  describe "record_word_replacements/3" do
    defp swap_word(user, original \\ "hello", translation \\ "hola") do
      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: original,
          target_translation: translation,
          language_pair: "en-es"
        })

      Vocabulary.get_or_create_user_word!(user.id, word.id)
      word
    end

    test "counts every occurrence as a replacement but the page as one exposure" do
      user = AccountsFixtures.user_fixture()
      word = swap_word(user)

      assert %{recorded: 1, skipped: 0} =
               Vocabulary.record_word_replacements(user.id, "en-es", %{"hello" => 7})

      updated = Vocabulary.get_user_word(user.id, word.id)
      assert updated.replacement_count == 7
      assert updated.exposure_count == 1
    end

    test "leaves words the page never showed untouched" do
      user = AccountsFixtures.user_fixture()
      seen = swap_word(user, "hello", "hola")
      unseen = swap_word(user, "world", "mundo")

      Vocabulary.record_word_replacements(user.id, "en-es", %{"hello" => 1})

      assert Vocabulary.get_user_word(user.id, seen.id).exposure_count == 1
      # The regression this function exists for: exposure used to be credited to
      # every active word on any page visit, whether or not it appeared.
      assert Vocabulary.get_user_word(user.id, unseen.id).exposure_count == 0
    end

    test "folds keys that reach the same entry into one row" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "run",
          target_translation: "correr",
          language_pair: "en-es",
          lemma: "run"
        })

      Vocabulary.get_or_create_user_word!(user.id, word.id)

      # A sentence-initial "Run" and a mid-sentence "run" are one entry. Both
      # must land on a single row: Postgres refuses an ON CONFLICT that touches
      # the same row twice in one statement.
      assert %{recorded: 1} =
               Vocabulary.record_word_replacements(user.id, "en-es", %{
                 "run" => 2,
                 "Run" => 3
               })

      updated = Vocabulary.get_user_word(user.id, word.id)
      assert updated.replacement_count == 5
      assert updated.exposure_count == 1
    end

    test "skips words the dictionary does not know" do
      user = AccountsFixtures.user_fixture()
      swap_word(user)

      assert %{recorded: 1, skipped: 1} =
               Vocabulary.record_word_replacements(user.id, "en-es", %{
                 "hello" => 1,
                 "bewilderment" => 1
               })
    end

    test "creates the row for a word reported before the pool held it" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      refute Vocabulary.get_user_word(user.id, word.id)

      Vocabulary.record_word_replacements(user.id, "en-es", %{"hello" => 2})

      user_word = Vocabulary.get_user_word(user.id, word.id)
      assert user_word.status == "hard"
      assert user_word.replacement_count == 2
      assert user_word.exposure_count == 1
    end

    test "clamps a count the client got wrong" do
      user = AccountsFixtures.user_fixture()
      word = swap_word(user)

      Vocabulary.record_word_replacements(user.id, "en-es", %{"hello" => -4})

      assert Vocabulary.get_user_word(user.id, word.id).replacement_count == 1
    end

    test "auto-promotes hard to simple after 50 pages with 0 reveals" do
      user = AccountsFixtures.user_fixture()
      word = swap_word(user)

      for _ <- 1..49 do
        Vocabulary.record_word_replacements(user.id, "en-es", %{"hello" => 1})
      end

      assert Vocabulary.get_user_word(user.id, word.id).status == "hard"

      Vocabulary.record_word_replacements(user.id, "en-es", %{"hello" => 1})

      assert Vocabulary.get_user_word(user.id, word.id).status == "simple"
    end

    test "auto-promotes simple to trivial after 100 pages with 0 reveals" do
      user = AccountsFixtures.user_fixture()
      word = swap_word(user)
      Vocabulary.rate_word(user.id, word.id, "simple")

      for _ <- 1..99 do
        Vocabulary.record_word_replacements(user.id, "en-es", %{"hello" => 1})
      end

      assert Vocabulary.get_user_word(user.id, word.id).status == "simple"

      Vocabulary.record_word_replacements(user.id, "en-es", %{"hello" => 1})

      assert Vocabulary.get_user_word(user.id, word.id).status == "trivial"
    end

    test "a word repeated on one page does not race through the thresholds" do
      user = AccountsFixtures.user_fixture()
      word = swap_word(user)

      # 60 occurrences on a single page is one encounter, not 60. Counting them
      # as exposures would graduate the word off the back of one article.
      Vocabulary.record_word_replacements(user.id, "en-es", %{"hello" => 60})

      assert Vocabulary.get_user_word(user.id, word.id).status == "hard"
    end
  end

  describe "get_user_stats/1" do
    test "returns zero stats for user with no words" do
      user = AccountsFixtures.user_fixture()
      stats = Vocabulary.get_user_stats(user.id)

      assert stats.total_words == 0
      assert stats.hard_words == 0
      assert stats.simple_words == 0
      assert stats.trivial_words == 0
      assert stats.total_reveals == 0
      assert stats.total_replacements == 0
    end

    test "returns correct stats after word interactions" do
      user = AccountsFixtures.user_fixture()

      {:ok, word1} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, word2} =
        Vocabulary.create_word(%{
          original_word: "world",
          target_translation: "mundo",
          language_pair: "en-es"
        })

      Vocabulary.get_or_create_user_word!(user.id, word1.id)
      Vocabulary.get_or_create_user_word!(user.id, word2.id)

      Vocabulary.rate_word(user.id, word1.id, "hard")
      Vocabulary.rate_word(user.id, word2.id, "trivial")

      {:ok, _} = Vocabulary.record_word_replacement(user.id, word1.id)
      {:ok, _} = Vocabulary.record_word_replacement(user.id, word2.id)
      {:ok, _} = Vocabulary.record_word_replacement(user.id, word2.id)

      stats = Vocabulary.get_user_stats(user.id)
      assert stats.total_words == 2
      assert stats.hard_words == 1
      assert stats.trivial_words == 1
      assert stats.simple_words == 0
      assert stats.total_replacements == 3
    end
  end

  describe "get_words_for_replacement/2" do
    test "returns all words including trivial" do
      user = AccountsFixtures.user_fixture()

      {:ok, word1} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, word2} =
        Vocabulary.create_word(%{
          original_word: "world",
          target_translation: "mundo",
          language_pair: "en-es"
        })

      {:ok, _word3} =
        Vocabulary.create_word(%{
          original_word: "foo",
          target_translation: "bar",
          language_pair: "en-es"
        })

      Vocabulary.get_or_create_user_word!(user.id, word1.id)
      Vocabulary.rate_word(user.id, word1.id, "hard")

      Vocabulary.get_or_create_user_word!(user.id, word2.id)
      Vocabulary.rate_word(user.id, word2.id, "trivial")

      results = Vocabulary.get_words_for_replacement(user.id, "en-es")
      original_words = Enum.map(results, & &1.word.original_word) |> Enum.sort()
      assert Enum.sort(["hello", "world", "foo"]) == original_words
    end

    test "filters by language_pair" do
      user = AccountsFixtures.user_fixture()

      {:ok, _} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, _} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "salom",
          language_pair: "en-uz"
        })

      Vocabulary.ensure_active_pool(user.id, "en-es")
      Vocabulary.ensure_active_pool(user.id, "en-uz")

      assert [%{word: word}] = Vocabulary.get_words_for_replacement(user.id, "en-es")
      assert word.target_translation == "hola"
    end

    test "withholds dictionary words the user has not been given yet" do
      user = AccountsFixtures.user_fixture()

      {:ok, _} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      assert Vocabulary.get_words_for_replacement(user.id, "en-es") == []
    end
  end

  describe "create_page_visit/1" do
    test "creates page visit" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, visit} =
               Vocabulary.create_page_visit(%{
                 user_id: user.id,
                 url: "https://example.com",
                 words_replaced: 5,
                 time_spent_seconds: 120
               })

      assert visit.url == "https://example.com"
      assert visit.words_replaced == 5
      assert visit.time_spent_seconds == 120
    end

    test "returns error with missing required fields" do
      assert {:error, changeset} = Vocabulary.create_page_visit(%{})
      assert errors_on(changeset).url
      assert errors_on(changeset).user_id
    end
  end

  describe "list_words_for_user/2" do
    test "returns words for user" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      _user_word = Vocabulary.get_or_create_user_word!(user.id, word.id)

      words = Vocabulary.list_words_for_user(user.id)
      assert length(words) == 1
    end

    test "filters by language_pair" do
      user = AccountsFixtures.user_fixture()

      {:ok, word_es} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, word_uz} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "salom",
          language_pair: "en-uz"
        })

      Vocabulary.get_or_create_user_word!(user.id, word_es.id)
      Vocabulary.get_or_create_user_word!(user.id, word_uz.id)

      assert length(Vocabulary.list_words_for_user(user.id, "en-es")) == 1
      assert length(Vocabulary.list_words_for_user(user.id, "en-uz")) == 1
      assert length(Vocabulary.list_words_for_user(user.id)) == 2
    end
  end

  describe "word metadata" do
    test "derives lemma and token_count from the entry" do
      assert {:ok, word} =
               Vocabulary.create_word(%{
                 original_word: "Running",
                 target_translation: "corriendo",
                 language_pair: "en-es"
               })

      assert word.lemma == "running"
      assert word.token_count == 1
      assert word.forms == %{}
    end

    test "counts tokens in a phrase entry" do
      assert {:ok, word} =
               Vocabulary.create_word(%{
                 original_word: "in front of",
                 target_translation: "delante de",
                 language_pair: "en-es"
               })

      assert word.token_count == 3
    end

    test "keeps an explicitly supplied lemma" do
      assert {:ok, word} =
               Vocabulary.create_word(%{
                 original_word: "ran",
                 target_translation: "corrió",
                 language_pair: "en-es",
                 lemma: "run"
               })

      assert word.lemma == "run"
    end

    test "rejects an unsupported language pair" do
      assert {:error, changeset} =
               Vocabulary.create_word(%{
                 original_word: "hello",
                 target_translation: "bonjour",
                 language_pair: "en-fr"
               })

      assert errors_on(changeset).language_pair
    end
  end

  describe "get_or_create_word!/4" do
    test "leaves frequency data unset when the caller does not know it" do
      word = Vocabulary.get_or_create_word!("hello", "hola", "en-es")

      assert word.frequency_rank == nil
      assert word.difficulty_score == nil
    end

    test "accepts extra attributes for a newly created word" do
      word =
        Vocabulary.get_or_create_word!("hello", "hola", "en-es", %{
          frequency_rank: 12,
          difficulty_score: 1,
          source: "import"
        })

      assert word.frequency_rank == 12
      assert word.source == "import"
    end
  end

  describe "upsert_word/1" do
    test "inserts a new entry" do
      assert {:ok, word} =
               Vocabulary.upsert_word(%{
                 original_word: "hello",
                 target_translation: "hola",
                 language_pair: "en-es",
                 frequency_rank: 40
               })

      assert word.frequency_rank == 40
    end

    test "updates an existing entry instead of failing on the unique index" do
      {:ok, first} =
        Vocabulary.upsert_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es",
          frequency_rank: 40
        })

      assert {:ok, second} =
               Vocabulary.upsert_word(%{
                 original_word: "hello",
                 target_translation: "buenas",
                 language_pair: "en-es",
                 frequency_rank: 12
               })

      assert second.id == first.id
      assert second.target_translation == "buenas"
      assert second.frequency_rank == 12
    end

    test "returns the changeset for invalid attributes" do
      assert {:error, changeset} =
               Vocabulary.upsert_word(%{original_word: "hello", language_pair: "en-fr"})

      assert errors_on(changeset).language_pair
    end
  end

  defp with_budget(user, budget) do
    {:ok, user} = Linguaswap.Accounts.update_user_settings(user, %{"word_budget" => budget})
    user
  end

  describe "active pool" do
    setup do
      user = AccountsFixtures.user_fixture()

      words =
        for rank <- 1..10 do
          {:ok, word} =
            Vocabulary.create_word(%{
              original_word: "word#{rank}",
              target_translation: "palabra#{rank}",
              language_pair: "en-es",
              frequency_rank: rank
            })

          word
        end

      %{user: user, words: words}
    end

    test "fills the pool up to the budget", %{user: user} do
      assert %{activated: 3, active: 3, budget: 3} =
               Vocabulary.ensure_active_pool(user.id, "en-es", 3)

      assert length(Vocabulary.active_pool(user.id, "en-es")) == 3
    end

    test "introduces words in frequency order", %{user: user} do
      Vocabulary.ensure_active_pool(user.id, "en-es", 3)

      assert ["word1", "word2", "word3"] =
               Vocabulary.active_pool(user.id, "en-es") |> Enum.map(& &1.word.original_word)
    end

    test "sorts words with no known frequency last", %{user: user} do
      {:ok, _unranked} =
        Vocabulary.create_word(%{
          original_word: "zzz",
          target_translation: "zeta",
          language_pair: "en-es"
        })

      Vocabulary.ensure_active_pool(user.id, "en-es", 10)

      refute "zzz" in (Vocabulary.active_pool(user.id, "en-es")
                       |> Enum.map(& &1.word.original_word))
    end

    test "is idempotent while the pool is full", %{user: user} do
      Vocabulary.ensure_active_pool(user.id, "en-es", 3)

      assert %{activated: 0, active: 3} = Vocabulary.ensure_active_pool(user.id, "en-es", 3)
    end

    test "does not remove words when the budget shrinks", %{user: user} do
      Vocabulary.ensure_active_pool(user.id, "en-es", 5)

      assert %{activated: 0, active: 5} = Vocabulary.ensure_active_pool(user.id, "en-es", 2)
    end

    test "stops when the dictionary runs out", %{user: user} do
      assert %{activated: 10, active: 10} = Vocabulary.ensure_active_pool(user.id, "en-es", 50)
    end

    test "stamps activated words with an activation time", %{user: user} do
      Vocabulary.ensure_active_pool(user.id, "en-es", 1)

      assert [%{user_word: user_word}] = Vocabulary.active_pool(user.id, "en-es")
      assert user_word.activated_at
      assert user_word.status == "hard"
    end

    test "ignores words from other language pairs", %{user: user} do
      {:ok, _} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "salom",
          language_pair: "en-uz"
        })

      Vocabulary.ensure_active_pool(user.id, "en-es", 50)

      assert Vocabulary.active_pool(user.id, "en-uz") == []
    end
  end

  describe "graduation refills the pool" do
    setup do
      user = AccountsFixtures.user_fixture() |> with_budget(2)

      words =
        for rank <- 1..5 do
          {:ok, word} =
            Vocabulary.create_word(%{
              original_word: "word#{rank}",
              target_translation: "palabra#{rank}",
              language_pair: "en-es",
              frequency_rank: rank
            })

          word
        end

      %{user: user, words: words}
    end

    test "rating a word trivial frees budget and introduces the next word", %{
      user: user,
      words: [first | _]
    } do
      Vocabulary.ensure_active_pool(user.id, "en-es")

      assert ["word1", "word2"] =
               Vocabulary.active_pool(user.id, "en-es") |> Enum.map(& &1.word.original_word)

      {:ok, _} = Vocabulary.rate_word(user.id, first.id, "trivial")

      assert ["word2", "word3"] =
               Vocabulary.active_pool(user.id, "en-es") |> Enum.map(& &1.word.original_word)
    end

    test "rating a word hard or simple does not introduce new words", %{
      user: user,
      words: [first | _]
    } do
      Vocabulary.ensure_active_pool(user.id, "en-es")
      {:ok, _} = Vocabulary.rate_word(user.id, first.id, "simple")

      assert length(Vocabulary.active_pool(user.id, "en-es")) == 2
    end

    test "graduated words are still served to the extension", %{user: user, words: [first | _]} do
      Vocabulary.ensure_active_pool(user.id, "en-es")
      {:ok, _} = Vocabulary.rate_word(user.id, first.id, "trivial")

      served =
        Vocabulary.get_words_for_replacement(user.id, "en-es")
        |> Enum.map(& &1.word.original_word)

      assert "word1" in served
      assert length(served) == 3
    end

    test "auto-promotion on reported swaps refills the pool", %{user: user, words: words} do
      Vocabulary.ensure_active_pool(user.id, "en-es")

      # Drive the first word to the auto-promotion thresholds without reveals.
      [first | _] = words
      user_word = Vocabulary.get_user_word(user.id, first.id)

      {:ok, _} =
        user_word
        |> Linguaswap.Vocabulary.UserWord.changeset(%{status: "simple", exposure_count: 100})
        |> Linguaswap.Repo.update()

      Vocabulary.record_word_replacements(user.id, "en-es", %{first.original_word => 1})

      assert Vocabulary.get_user_word(user.id, first.id).status == "trivial"

      active = Vocabulary.active_pool(user.id, "en-es") |> Enum.map(& &1.word.original_word)
      assert length(active) == 2
      refute "word1" in active
    end
  end

  describe "word_budget/1" do
    test "defaults when unset or unusable" do
      assert Vocabulary.word_budget(%{}) == Vocabulary.default_word_budget()
      assert Vocabulary.word_budget(nil) == Vocabulary.default_word_budget()
      assert Vocabulary.word_budget(%{"word_budget" => 0}) == Vocabulary.default_word_budget()

      assert Vocabulary.word_budget(%{"word_budget" => "many"}) ==
               Vocabulary.default_word_budget()
    end

    test "reads an integer or numeric string from settings" do
      assert Vocabulary.word_budget(%{"word_budget" => 25}) == 25
      assert Vocabulary.word_budget(%{"word_budget" => "25"}) == 25
    end
  end

  describe "swap_density/1" do
    test "defaults when unset or unusable" do
      assert Vocabulary.swap_density(%{}) == Vocabulary.default_swap_density()
      assert Vocabulary.swap_density(nil) == Vocabulary.default_swap_density()

      assert Vocabulary.swap_density(%{"swap_density" => "half"}) ==
               Vocabulary.default_swap_density()

      # A negative share is nonsense rather than a request for none.
      assert Vocabulary.swap_density(%{"swap_density" => -0.5}) ==
               Vocabulary.default_swap_density()
    end

    test "reads a number or numeric string from settings" do
      assert Vocabulary.swap_density(%{"swap_density" => 0.2}) == 0.2
      assert Vocabulary.swap_density(%{"swap_density" => "0.2"}) == 0.2
    end

    test "zero is a real setting, unlike a zero budget" do
      # Swapping nothing turns the extension off for a while without logging out
      # of it; carrying no words at all is only ever a mistake.
      assert Vocabulary.swap_density(%{"swap_density" => 0}) == 0.0
    end

    test "clamps an over-large share instead of rejecting it" do
      assert Vocabulary.swap_density(%{"swap_density" => 4}) == 1.0
    end
  end

  describe "pool_stats/3" do
    test "reports active, graduated and remaining counts" do
      user = AccountsFixtures.user_fixture() |> with_budget(2)

      for rank <- 1..5 do
        {:ok, _} =
          Vocabulary.create_word(%{
            original_word: "word#{rank}",
            target_translation: "palabra#{rank}",
            language_pair: "en-es",
            frequency_rank: rank
          })
      end

      Vocabulary.ensure_active_pool(user.id, "en-es")
      [%{word: word} | _] = Vocabulary.active_pool(user.id, "en-es")
      {:ok, _} = Vocabulary.rate_word(user.id, word.id, "trivial")

      stats = Vocabulary.pool_stats(user.id, "en-es")
      assert stats == %{budget: 2, active: 2, graduated: 1, remaining: 2}
    end
  end

  describe "language_pair_for_target/1" do
    test "builds a supported pair" do
      assert Vocabulary.language_pair_for_target("es") == "en-es"
      assert Vocabulary.language_pair_for_target("uz") == "en-uz"
    end

    test "falls back for an unsupported target language" do
      assert Vocabulary.language_pair_for_target("fr") in Vocabulary.language_pairs()
    end
  end
end
