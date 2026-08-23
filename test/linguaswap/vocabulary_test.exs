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
      assert errors_on(changeset).target_translation
      assert errors_on(changeset).language_pair
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

  describe "increment_exposure/2" do
    test "increments exposure_count for hard and simple words" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      user_word = Vocabulary.get_or_create_user_word!(user.id, word.id)
      assert user_word.exposure_count == 0

      Vocabulary.increment_exposure(user.id, "en-es")

      updated = Vocabulary.get_user_word(user.id, word.id)
      assert updated.exposure_count == 1
    end

    test "does not increment exposure for trivial words" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      Vocabulary.get_or_create_user_word!(user.id, word.id)
      Vocabulary.rate_word(user.id, word.id, "trivial")

      Vocabulary.increment_exposure(user.id, "en-es")

      updated = Vocabulary.get_user_word(user.id, word.id)
      assert updated.exposure_count == 0
    end

    test "auto-promotes hard to simple after 50 exposures with 0 reveals" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      Vocabulary.get_or_create_user_word!(user.id, word.id)

      for _ <- 1..49 do
        Vocabulary.increment_exposure(user.id, "en-es")
      end

      uw = Vocabulary.get_user_word(user.id, word.id)
      assert uw.status == "hard"

      Vocabulary.increment_exposure(user.id, "en-es")

      uw = Vocabulary.get_user_word(user.id, word.id)
      assert uw.status == "simple"
    end

    test "auto-promotes simple to trivial after 100 exposures with 0 reveals" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      Vocabulary.get_or_create_user_word!(user.id, word.id)
      Vocabulary.rate_word(user.id, word.id, "simple")

      for _ <- 1..99 do
        Vocabulary.increment_exposure(user.id, "en-es")
      end

      uw = Vocabulary.get_user_word(user.id, word.id)
      assert uw.status == "simple"

      Vocabulary.increment_exposure(user.id, "en-es")

      uw = Vocabulary.get_user_word(user.id, word.id)
      assert uw.status == "trivial"
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
               Vocabulary.upsert_word(%{original_word: "hello", language_pair: "en-es"})

      assert errors_on(changeset).target_translation
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

    test "auto-promotion on page visits refills the pool", %{user: user, words: words} do
      Vocabulary.ensure_active_pool(user.id, "en-es")

      # Drive the first word to the auto-promotion thresholds without reveals.
      [first | _] = words
      user_word = Vocabulary.get_user_word(user.id, first.id)

      {:ok, _} =
        user_word
        |> Linguaswap.Vocabulary.UserWord.changeset(%{status: "simple", exposure_count: 100})
        |> Linguaswap.Repo.update()

      Vocabulary.increment_exposure(user.id, "en-es")

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
