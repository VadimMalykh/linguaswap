defmodule Linguaswap.Vocabulary do
  @moduledoc """
  The Vocabulary context.
  """

  import Ecto.Query, warn: false
  alias Linguaswap.Repo
  alias Linguaswap.Vocabulary.{Word, UserWord, PageVisit}

  @valid_statuses ~w(hard simple trivial)

  def list_words_for_user(user_id, language_pair \\ nil) do
    query =
      from w in Word, join: uw in UserWord, on: w.id == uw.word_id, where: uw.user_id == ^user_id

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
        {:ok, word} =
          create_word(%{
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
        {:ok, user_word} =
          %UserWord{user_id: user_id, word_id: word_id}
          |> UserWord.changeset(%{})
          |> Repo.insert()

        user_word

      user_word ->
        user_word
    end
  end

  def record_word_reveal(user_id, word_id) do
    user_word = get_or_create_user_word!(user_id, word_id)

    updates = %{
      reveal_count: user_word.reveal_count + 1,
      last_revealed_at: DateTime.utc_now()
    }

    updates =
      cond do
        user_word.status == "trivial" ->
          Map.put(updates, :status, "simple")

        user_word.status == "simple" and
            user_word.reveal_count + 1 > max(user_word.exposure_count * 0.5, 3) ->
          Map.put(updates, :status, "hard")

        true ->
          updates
      end

    user_word
    |> UserWord.changeset(updates)
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

  def rate_word(user_id, word_id, status) when status in @valid_statuses do
    user_word = get_or_create_user_word!(user_id, word_id)

    user_word
    |> UserWord.changeset(%{status: status})
    |> Repo.update()
  end

  def rate_word(_user_id, _word_id, _status), do: {:error, :invalid_status}

  def increment_exposure(user_id, language_pair) do
    user_word_ids =
      from(uw in UserWord,
        join: w in Word,
        on: w.id == uw.word_id,
        where: uw.user_id == ^user_id,
        where: w.language_pair == ^language_pair,
        where: uw.status in ["hard", "simple"],
        select: uw.id
      )
      |> Repo.all()

    unless user_word_ids == [] do
      from(uw in UserWord, where: uw.id in ^user_word_ids)
      |> Repo.update_all(inc: [exposure_count: 1])
    end

    check_auto_promotions(user_id, user_word_ids)
  end

  defp check_auto_promotions(_user_id, user_word_ids) do
    unless user_word_ids == [] do
      words_to_promote =
        from(uw in UserWord,
          where: uw.id in ^user_word_ids,
          select: uw
        )
        |> Repo.all()

      Enum.each(words_to_promote, fn uw ->
        new_status = maybe_auto_promote(uw)

        if new_status && new_status != uw.status do
          uw
          |> UserWord.changeset(%{status: new_status})
          |> Repo.update()
        end
      end)
    end
  end

  defp maybe_auto_promote(%UserWord{status: "hard", exposure_count: exp, reveal_count: rev})
       when exp >= 50 and rev == 0,
       do: "simple"

  defp maybe_auto_promote(%UserWord{status: "simple", exposure_count: exp, reveal_count: rev})
       when exp >= 100 and rev == 0,
       do: "trivial"

  defp maybe_auto_promote(_), do: nil

  def create_page_visit(%{user_id: user_id} = attrs) do
    attrs = Map.delete(attrs, :user_id)

    %PageVisit{user_id: user_id}
    |> PageVisit.changeset(attrs)
    |> Repo.insert()
  end

  def create_page_visit(attrs) when is_map(attrs) do
    %PageVisit{}
    |> PageVisit.changeset(attrs)
    |> Repo.insert()
  end

  def get_user_stats(user_id) do
    user_words = Repo.all(from uw in UserWord, where: uw.user_id == ^user_id)

    %{
      total_words: length(user_words),
      hard_words: Enum.count(user_words, &(&1.status == "hard")),
      simple_words: Enum.count(user_words, &(&1.status == "simple")),
      trivial_words: Enum.count(user_words, &(&1.status == "trivial")),
      total_reveals: Enum.reduce(user_words, 0, &(&1.reveal_count + &2)),
      total_replacements: Enum.reduce(user_words, 0, &(&1.replacement_count + &2))
    }
  end

  def get_words_for_replacement(user_id, language_pair) do
    from(w in Word,
      left_join: uw in UserWord,
      on: w.id == uw.word_id and uw.user_id == ^user_id,
      where: w.language_pair == ^language_pair,
      select: %{word: w, user_word: uw}
    )
    |> Repo.all()
  end
end
