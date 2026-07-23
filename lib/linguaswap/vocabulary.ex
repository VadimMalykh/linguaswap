defmodule Linguaswap.Vocabulary do
  @moduledoc """
  The Vocabulary context.
  """

  import Ecto.Query, warn: false
  alias Linguaswap.Repo
  alias Linguaswap.Vocabulary.{Word, UserWord, PageVisit}

  def list_words_for_user(user_id, language_pair \\ nil) do
    query =
      from w in Word,
        join: uw in UserWord, on: w.id == uw.word_id,
        where: uw.user_id == ^user_id

    query =
      if language_pair do
        from [w, uw] in query, where: w.language_pair == ^language_pair
      else
        query
      end

    Repo.all(query)
  end

  def get_word_by_original(original_word, language_pair) do
    Repo.get_by(Word, original_word: original_word, language_pair: language_pair)
  end

  def create_word(attrs \\ %{}) do
    %Word{}
    |> Word.changeset(attrs)
    |> Repo.insert()
  end

  def get_or_create_word!(original_word, target_translation, language_pair) do
    case Repo.get_by(Word, original_word: original_word, language_pair: language_pair) do
      nil ->
        {:ok, word} = create_word(%{
          original_word: original_word,
          target_translation: target_translation,
          language_pair: language_pair,
          frequency_rank: 0,
          difficulty_score: 0
        })
        word

      word ->
        word
    end
  end

  def get_user_word(user_id, word_id) do
    Repo.get_by(UserWord, user_id: user_id, word_id: word_id)
  end

  def get_or_create_user_word!(user_id, word_id) do
    case Repo.get_by(UserWord, user_id: user_id, word_id: word_id) do
      nil ->
        {:ok, user_word} = %UserWord{}
        |> UserWord.changeset(%{user_id: user_id, word_id: word_id})
        |> Repo.insert()
        user_word

      user_word ->
        user_word
    end
  end

  def record_word_reveal(user_id, word_id) do
    user_word = get_or_create_user_word!(user_id, word_id)

    user_word
    |> UserWord.changeset(%{
      reveal_count: user_word.reveal_count + 1,
      last_revealed_at: DateTime.utc_now(),
      status: calculate_status(user_word.reveal_count + 1)
    })
    |> Repo.update()
  end

  def record_word_replacement(user_id, word_id) do
    user_word = get_or_create_user_word!(user_id, word_id)

    user_word
    |> UserWord.changeset(%{
      replacement_count: user_word.replacement_count + 1
    })
    |> Repo.update()
  end

  defp calculate_status(reveal_count) do
    cond do
      reveal_count == 0 -> "new"
      reveal_count < 3 -> "learning"
      true -> "known"
    end
  end

  def create_page_visit(attrs \\ %{}) do
    %PageVisit{}
    |> PageVisit.changeset(attrs)
    |> Repo.insert()
  end

  def get_user_stats(user_id) do
    user_words = Repo.all(from uw in UserWord, where: uw.user_id == ^user_id)

    %{
      total_words: length(user_words),
      known_words: Enum.count(user_words, &(&1.status == "known")),
      learning_words: Enum.count(user_words, &(&1.status == "learning")),
      new_words: Enum.count(user_words, &(&1.status == "new")),
      total_reveals: Enum.reduce(user_words, 0, &(&1.reveal_count + &2)),
      total_replacements: Enum.reduce(user_words, 0, &(&1.replacement_count + &2))
    }
  end

  def get_words_for_replacement(user_id, language_pair) do
    from(w in Word,
      left_join: uw in UserWord, on: w.id == uw.word_id and uw.user_id == ^user_id,
      where: w.language_pair == ^language_pair,
      where: uw.status in ["learning", "known"] or is_nil(uw.id),
      select: %{word: w, user_word: uw}
    )
    |> Repo.all()
  end
end
