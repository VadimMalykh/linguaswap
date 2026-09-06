defmodule LinguaswapWeb.ApiController do
  use LinguaswapWeb, :controller

  alias Linguaswap.Vocabulary
  alias Linguaswap.Vocabulary.Word
  alias Linguaswap.Accounts

  action_fallback LinguaswapWeb.FallbackController

  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid email or password"})

      user ->
        token = Accounts.generate_user_session_token(user)
        encoded = Base.url_encode64(token, padding: false)

        json(conn, %{
          token: encoded,
          user: %{id: user.id, email: user.email, target_language: user.target_language}
        })
    end
  end

  def get_words(conn, %{"language_pair" => language_pair}) do
    user = conn.assigns.current_scope.user
    budget = Vocabulary.word_budget(user.settings)

    # Fetching words is the natural moment to top the pool back up: it happens on
    # every page load and reflects any words that graduated since the last one.
    Vocabulary.ensure_active_pool(user.id, language_pair, budget)

    words_data = Vocabulary.get_words_for_replacement(user.id, language_pair)

    result =
      Enum.map(words_data, fn %{word: word, user_word: user_word} ->
        status = if user_word, do: user_word.status, else: "hard"
        reveal_count = if user_word, do: user_word.reveal_count, else: 0

        %{
          original: word.original_word,
          # The client keys its lookup table on the lemma as well as the
          # spelling, so page text like "running" reaches the "run" entry.
          lemma: word.lemma,
          translation: word.target_translation,
          # 1 for a word, >1 for a phrase. The client walks n-grams only as far
          # as the longest entry it was actually sent, so a user whose pool
          # holds no phrases pays nothing for the phrase pass.
          token_count: word.token_count,
          # Part of speech and inflected forms (Phase 4). The client detects
          # the English feature on the page word — a past tense, a plural — and
          # picks the matching form; `pos` is what separates the plural reading
          # of an "-s" from the third-person one. Unreviewed forms are withheld,
          # so the client falls back to the base translation for them.
          pos: word.pos,
          forms: Word.servable_forms(word),
          # Romanised pronunciation, for a target script the reader cannot sound
          # out — pinyin for Chinese, `nil` for Spanish and Uzbek, whose written
          # form is already the pronunciation guide. The client shows it beside
          # the swap rather than instead of it.
          pronunciation: word.pronunciation,
          status: status,
          reveal_count: reveal_count
        }
      end)

    json(conn, %{
      words: result,
      pool: Vocabulary.pool_stats(user.id, language_pair, budget),
      # How much of a sentence the client may swap. Sent with the dictionary
      # because it governs how the dictionary is used, and because it is a
      # per-user learning setting the extension should not be guessing at.
      swap: %{max_density: Vocabulary.swap_density(user.settings)}
    })
  end

  def record_reveal(conn, %{"word" => original_word, "language_pair" => language_pair}) do
    user = conn.assigns.current_scope.user

    case Vocabulary.get_word_by_original_or_lemma(original_word, language_pair) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Word not found"})

      word ->
        {:ok, _} = Vocabulary.record_word_reveal(user.id, word.id)
        json(conn, %{success: true})
    end
  end

  @doc """
  Records the swaps the client made on one page.

  The batch form is what the content script sends once a page has settled:

      {"words": [{"word": "run", "count": 3}, {"word": "be", "count": 7}],
       "language_pair": "en-es"}

  A bare list of words is accepted too, as is the original single-`word` body,
  so an older extension build keeps working.
  """
  def record_replacement(conn, %{"words" => words, "language_pair" => language_pair})
      when is_list(words) do
    user = conn.assigns.current_scope.user
    summary = Vocabulary.record_word_replacements(user.id, language_pair, swap_counts(words))

    json(conn, %{
      success: true,
      recorded: summary.recorded,
      skipped: summary.skipped,
      pool: summary.pool
    })
  end

  def record_replacement(conn, %{"word" => original_word, "language_pair" => language_pair}) do
    user = conn.assigns.current_scope.user

    case Vocabulary.get_word_by_original_or_lemma(original_word, language_pair) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Word not found"})

      word ->
        # Routed through the batch path so a single report counts as an exposure
        # too, exactly as one entry in a batch of one would.
        summary =
          Vocabulary.record_word_replacements(user.id, language_pair, %{word.original_word => 1})

        json(conn, %{success: true, recorded: summary.recorded})
    end
  end

  # Accepts ["run", "be"] as well as [%{"word" => "run", "count" => 3}].
  defp swap_counts(words) do
    Enum.reduce(words, %{}, fn
      %{"word" => word} = entry, acc when is_binary(word) ->
        Map.update(acc, word, count_of(entry), &(&1 + count_of(entry)))

      word, acc when is_binary(word) ->
        Map.update(acc, word, 1, &(&1 + 1))

      _, acc ->
        acc
    end)
  end

  defp count_of(%{"count" => count}) when is_integer(count) and count > 0, do: count
  defp count_of(_), do: 1

  def rate_word(conn, %{
        "word" => original_word,
        "language_pair" => language_pair,
        "status" => status
      }) do
    user = conn.assigns.current_scope.user

    case Vocabulary.get_word_by_original_or_lemma(original_word, language_pair) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Word not found"})

      word ->
        case Vocabulary.rate_word(user.id, word.id, status) do
          {:ok, user_word} ->
            json(conn, %{success: true, status: user_word.status})

          {:error, :invalid_status} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Invalid status"})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{
              error: "Invalid status",
              errors: Ecto.Changeset.traverse_errors(changeset, &inspect/1)
            })
        end
    end
  end

  # A page visit is history and timing only. Exposure used to be counted here,
  # for every active word at once — see `Vocabulary.record_word_replacements/3`,
  # which now counts the words the page actually showed. `language_pair` is
  # still accepted so older extension builds post successfully.
  def record_page_visit(conn, %{
        "url" => url,
        "words_replaced" => words_replaced,
        "time_spent" => time_spent
      }) do
    user = conn.assigns.current_scope.user

    {:ok, _} =
      Vocabulary.create_page_visit(%{
        user_id: user.id,
        url: url,
        words_replaced: words_replaced,
        time_spent_seconds: time_spent
      })

    json(conn, %{success: true})
  end

  def get_stats(conn, _params) do
    user = conn.assigns.current_scope.user
    stats = Vocabulary.get_user_stats(user.id)

    json(conn, %{stats: stats})
  end

  def get_settings(conn, _params) do
    user = conn.assigns.current_scope.user

    json(conn, %{
      settings: %{
        target_language: user.target_language,
        settings: user.settings || %{}
      }
    })
  end

  def update_settings(conn, %{"target_language" => target_language, "settings" => settings}) do
    user = conn.assigns.current_scope.user

    {:ok, user} = Accounts.update_user_target_language(user, target_language)
    {:ok, _} = Accounts.update_user_settings(user, settings || %{})

    json(conn, %{
      settings: %{
        target_language: user.target_language,
        settings: user.settings
      }
    })
  end
end
