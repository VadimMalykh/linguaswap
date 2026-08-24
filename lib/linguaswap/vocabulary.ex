defmodule Linguaswap.Vocabulary do
  @moduledoc """
  The Vocabulary context.
  """

  import Ecto.Query, warn: false
  alias Linguaswap.Repo
  alias Linguaswap.Accounts.User
  alias Linguaswap.Vocabulary.{Word, UserWord, PageVisit}

  @valid_statuses ~w(hard simple trivial)

  # Statuses that occupy a slot in the user's active learning pool. `trivial`
  # words are still replaced on the page, but they are mastered and no longer
  # cost budget — that is what frees room for new words.
  @active_statuses ~w(hard simple)

  @default_word_budget 50

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

  @doc """
  Resolves a word the extension reported, by spelling or by lemma.

  The client lemmatizes page text, so the token it swapped ("running") is not
  always the entry it matched ("run"). It sends the entry's own spelling back,
  but older builds — and any caller working from page text — send the surface
  form, so the lemma is accepted as a fallback. An exact spelling always wins;
  among entries sharing a lemma the most frequent one does.
  """
  def get_word_by_original_or_lemma(word, language_pair) do
    normalized = String.downcase(word)

    from(w in Word,
      where: w.language_pair == ^language_pair,
      where: w.original_word == ^word or w.lemma == ^normalized,
      order_by: [
        asc: fragment("case when ? = ? then 0 else 1 end", w.original_word, ^word),
        asc_nulls_last: w.frequency_rank,
        asc: w.id
      ],
      limit: 1
    )
    |> Repo.one()
  end

  def create_word(attrs \\ %{}) do
    %Word{}
    |> Word.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Language pairs the dictionary supports.
  """
  defdelegate language_pairs(), to: Word

  def get_or_create_word!(original_word, target_translation, language_pair, attrs \\ %{}) do
    case Repo.get_by(Word, original_word: original_word, language_pair: language_pair) do
      nil ->
        # frequency_rank/difficulty_score are deliberately left unset when the
        # caller doesn't know them: they drive frontier ordering, and a real
        # `nil` sorts last rather than pretending the word is the most common
        # one in the language.
        {:ok, word} =
          attrs
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.merge(%{
            "original_word" => original_word,
            "target_translation" => target_translation,
            "language_pair" => language_pair
          })
          |> create_word()

        word

      word ->
        word
    end
  end

  @doc """
  Inserts a dictionary entry, updating it in place when the
  `original_word`/`language_pair` pair already exists.

  Used by the word importer so re-running an import refreshes translations and
  frequency data instead of failing on the unique index.
  """
  def upsert_word(attrs) do
    changeset = Word.changeset(%Word{}, attrs)

    with %Ecto.Changeset{valid?: true} <- changeset do
      replaceable =
        changeset.changes
        |> Map.take([
          :target_translation,
          :frequency_rank,
          :difficulty_score,
          :lemma,
          :pos,
          :token_count,
          :forms,
          :source
        ])
        |> Map.keys()

      Repo.insert(changeset,
        on_conflict: {:replace, [:updated_at | replaceable]},
        conflict_target: [:original_word, :language_pair],
        returning: true
      )
    else
      changeset -> {:error, changeset}
    end
  end

  def get_user_word(user_id, word_id) do
    Repo.get_by(UserWord, user_id: user_id, word_id: word_id)
  end

  def get_or_create_user_word!(user_id, word_id) do
    case Repo.get_by(UserWord, user_id: user_id, word_id: word_id) do
      nil ->
        # A word the user has interacted with is in play whether or not the
        # budget put it there, so it gets an activation stamp like any other.
        {:ok, user_word} =
          %UserWord{user_id: user_id, word_id: word_id}
          |> UserWord.changeset(%{activated_at: DateTime.utc_now(:second)})
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

    result =
      user_word
      |> UserWord.changeset(%{status: status})
      |> Repo.update()

    # Rating a word "trivial" graduates it just as auto-promotion does, so the
    # freed budget should be refilled straight away.
    with {:ok, updated} <- result do
      if status == "trivial", do: refill_pool_for_word(user_id, word_id)
      {:ok, updated}
    end
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

    # Auto-promotion to `trivial` is the main way budget frees up, so the pool
    # is refilled on the same pass rather than waiting for the next page load.
    ensure_active_pool(user_id, language_pair)
  end

  defp refill_pool_for_word(user_id, word_id) do
    case Repo.get(Word, word_id) do
      nil -> :ok
      word -> ensure_active_pool(user_id, word.language_pair)
    end
  end

  defp budget_for_user(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.settings)
    |> Repo.one()
    |> word_budget()
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

  @doc """
  Words to send to the extension for a language pair.

  This is the user's own vocabulary — the active pool plus everything they have
  graduated — not the whole dictionary. Words the user has not reached yet are
  withheld until the budget has room for them (see `ensure_active_pool/3`).
  """
  def get_words_for_replacement(user_id, language_pair) do
    from(uw in UserWord,
      join: w in Word,
      on: w.id == uw.word_id,
      where: uw.user_id == ^user_id,
      where: w.language_pair == ^language_pair,
      order_by: [asc_nulls_last: w.frequency_rank, asc: w.id],
      select: %{word: w, user_word: uw}
    )
    |> Repo.all()
  end

  ## Active pool (adaptive word intake)

  @doc """
  Number of active words a user carries by default.
  """
  def default_word_budget, do: @default_word_budget

  @doc """
  Resolves the user's word budget from their settings map.

  Takes the raw settings rather than a `User` struct so the Vocabulary context
  stays independent of Accounts.
  """
  def word_budget(settings) when is_map(settings) do
    case Map.get(settings, "word_budget") do
      budget when is_integer(budget) and budget > 0 ->
        budget

      budget when is_binary(budget) ->
        case Integer.parse(budget) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> @default_word_budget
        end

      _ ->
        @default_word_budget
    end
  end

  def word_budget(_settings), do: @default_word_budget

  @doc """
  The language pair served for a user's target language.
  """
  def language_pair_for_target(target_language) do
    pair = "en-#{target_language}"
    if pair in Word.language_pairs(), do: pair, else: hd(Word.language_pairs())
  end

  @doc """
  Words the user is currently learning: `hard` or `simple`, in frontier order.
  """
  def active_pool(user_id, language_pair) do
    from(uw in UserWord,
      join: w in Word,
      on: w.id == uw.word_id,
      where: uw.user_id == ^user_id,
      where: w.language_pair == ^language_pair,
      where: uw.status in ^@active_statuses,
      order_by: [asc_nulls_last: w.frequency_rank, asc: w.id],
      select: %{word: w, user_word: uw}
    )
    |> Repo.all()
  end

  @doc """
  Tops the active pool back up to `budget` words.

  This is the heart of the budget model: the user carries a fixed number of
  words in flight, and words only enter as others graduate to `trivial`.
  Candidates are taken in frequency order, so the most useful unseen word is
  always the next one introduced. Entries with no known frequency sort last
  rather than first.

  The budget defaults to the user's own setting, so background top-ups triggered
  by graduation use the same number as an explicit call from the API.

  Returns a summary of the pool after the top-up.
  """
  def ensure_active_pool(user_id, language_pair, budget \\ nil) do
    budget = max(budget || budget_for_user(user_id), 0)
    active = active_pool_size(user_id, language_pair)
    activated = activate_frontier_words(user_id, language_pair, budget - active)

    %{budget: budget, active: active + activated, activated: activated}
  end

  @doc """
  Dictionary entries the user has not been given yet, in the order they will be
  introduced.
  """
  def frontier_words(user_id, language_pair, limit) do
    from(w in Word,
      left_join: uw in UserWord,
      on: uw.word_id == w.id and uw.user_id == ^user_id,
      where: w.language_pair == ^language_pair,
      where: is_nil(uw.id),
      order_by: [asc_nulls_last: w.frequency_rank, asc: w.id],
      limit: ^limit,
      select: w
    )
    |> Repo.all()
  end

  @doc """
  Pool state for a user and language pair, for the dashboard and the API.
  """
  def pool_stats(user_id, language_pair, budget \\ nil) do
    budget = budget || budget_for_user(user_id)

    counts =
      from(uw in UserWord,
        join: w in Word,
        on: w.id == uw.word_id,
        where: uw.user_id == ^user_id,
        where: w.language_pair == ^language_pair,
        group_by: uw.status,
        select: {uw.status, count(uw.id)}
      )
      |> Repo.all()
      |> Map.new()

    active = Enum.reduce(@active_statuses, 0, &(&2 + Map.get(counts, &1, 0)))

    %{
      budget: budget,
      active: active,
      graduated: Map.get(counts, "trivial", 0),
      remaining: count_frontier_words(user_id, language_pair)
    }
  end

  defp active_pool_size(user_id, language_pair) do
    from(uw in UserWord,
      join: w in Word,
      on: w.id == uw.word_id,
      where: uw.user_id == ^user_id,
      where: w.language_pair == ^language_pair,
      where: uw.status in ^@active_statuses,
      select: count(uw.id)
    )
    |> Repo.one()
  end

  defp count_frontier_words(user_id, language_pair) do
    from(w in Word,
      left_join: uw in UserWord,
      on: uw.word_id == w.id and uw.user_id == ^user_id,
      where: w.language_pair == ^language_pair,
      where: is_nil(uw.id),
      select: count(w.id)
    )
    |> Repo.one()
  end

  defp activate_frontier_words(_user_id, _language_pair, deficit) when deficit <= 0, do: 0

  defp activate_frontier_words(user_id, language_pair, deficit) do
    now = DateTime.utc_now(:second)

    entries =
      user_id
      |> frontier_words(language_pair, deficit)
      |> Enum.map(fn word ->
        %{
          user_id: user_id,
          word_id: word.id,
          status: "hard",
          reveal_count: 0,
          replacement_count: 0,
          exposure_count: 0,
          activated_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    {activated, _} =
      Repo.insert_all(UserWord, entries,
        on_conflict: :nothing,
        conflict_target: [:user_id, :word_id]
      )

    activated
  end
end
