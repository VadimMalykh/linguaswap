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
    test "creates user_word for new combination" do
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
      assert user_word.status == "new"
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
    test "increments reveal_count and updates status" do
      user = AccountsFixtures.user_fixture()

      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, uw} = Vocabulary.record_word_reveal(user.id, word.id)
      assert uw.reveal_count == 1
      assert uw.status == "learning"
      assert uw.last_revealed_at != nil

      {:ok, uw} = Vocabulary.record_word_reveal(user.id, word.id)
      assert uw.reveal_count == 2
      assert uw.status == "learning"

      {:ok, uw} = Vocabulary.record_word_reveal(user.id, word.id)
      assert uw.reveal_count == 3
      assert uw.status == "known"
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

  describe "get_user_stats/1" do
    test "returns zero stats for user with no words" do
      user = AccountsFixtures.user_fixture()
      stats = Vocabulary.get_user_stats(user.id)

      assert stats.total_words == 0
      assert stats.known_words == 0
      assert stats.learning_words == 0
      assert stats.new_words == 0
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

      # word1: 1 reveal -> learning
      {:ok, _} = Vocabulary.record_word_reveal(user.id, word1.id)

      # word2: 3 reveals -> known
      {:ok, _} = Vocabulary.record_word_reveal(user.id, word2.id)
      {:ok, _} = Vocabulary.record_word_reveal(user.id, word2.id)
      {:ok, _} = Vocabulary.record_word_reveal(user.id, word2.id)

      # record some replacements
      {:ok, _} = Vocabulary.record_word_replacement(user.id, word1.id)
      {:ok, _} = Vocabulary.record_word_replacement(user.id, word2.id)
      {:ok, _} = Vocabulary.record_word_replacement(user.id, word2.id)

      stats = Vocabulary.get_user_stats(user.id)
      assert stats.total_words == 2
      assert stats.known_words == 1
      assert stats.learning_words == 1
      assert stats.new_words == 0
      assert stats.total_reveals == 4
      assert stats.total_replacements == 3
    end
  end

  describe "get_words_for_replacement/2" do
    test "returns learning, known, and unseen words" do
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

      # word1: learning (1 reveal)
      {:ok, _} = Vocabulary.record_word_reveal(user.id, word1.id)

      # word2: known (3 reveals)
      {:ok, _} = Vocabulary.record_word_reveal(user.id, word2.id)
      {:ok, _} = Vocabulary.record_word_reveal(user.id, word2.id)
      {:ok, _} = Vocabulary.record_word_reveal(user.id, word2.id)

      # word3: unseen (no interaction)

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

      results = Vocabulary.get_words_for_replacement(user.id, "en-es")
      assert length(results) == 1
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
end
