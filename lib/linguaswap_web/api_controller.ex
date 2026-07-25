defmodule LinguaswapWeb.ApiController do
  use LinguaswapWeb, :controller

  alias Linguaswap.Vocabulary
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
    words_data = Vocabulary.get_words_for_replacement(user.id, language_pair)

    result =
      Enum.map(words_data, fn %{word: word, user_word: user_word} ->
        status = if user_word, do: user_word.status, else: "hard"
        reveal_count = if user_word, do: user_word.reveal_count, else: 0

        %{
          original: word.original_word,
          translation: word.target_translation,
          status: status,
          reveal_count: reveal_count
        }
      end)

    json(conn, %{words: result})
  end

  def record_reveal(conn, %{"word" => original_word, "language_pair" => language_pair}) do
    user = conn.assigns.current_scope.user

    case Vocabulary.get_word_by_original(original_word, language_pair) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Word not found"})

      word ->
        {:ok, _} = Vocabulary.record_word_reveal(user.id, word.id)
        json(conn, %{success: true})
    end
  end

  def record_replacement(conn, %{"word" => original_word, "language_pair" => language_pair}) do
    user = conn.assigns.current_scope.user

    case Vocabulary.get_word_by_original(original_word, language_pair) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Word not found"})

      word ->
        {:ok, _} = Vocabulary.record_word_replacement(user.id, word.id)
        json(conn, %{success: true})
    end
  end

  def rate_word(conn, %{
        "word" => original_word,
        "language_pair" => language_pair,
        "status" => status
      }) do
    user = conn.assigns.current_scope.user

    case Vocabulary.get_word_by_original(original_word, language_pair) do
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

  def record_page_visit(conn, %{
        "url" => url,
        "words_replaced" => words_replaced,
        "time_spent" => time_spent,
        "language_pair" => language_pair
      }) do
    user = conn.assigns.current_scope.user

    Vocabulary.increment_exposure(user.id, language_pair)

    {:ok, _} =
      Vocabulary.create_page_visit(%{
        user_id: user.id,
        url: url,
        words_replaced: words_replaced,
        time_spent_seconds: time_spent
      })

    json(conn, %{success: true})
  end

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
