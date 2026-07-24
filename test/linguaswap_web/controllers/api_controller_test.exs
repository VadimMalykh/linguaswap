defmodule LinguaswapWeb.ApiControllerTest do
  use LinguaswapWeb.ConnCase

  alias Linguaswap.Vocabulary

  setup :register_and_log_in_user

  describe "GET /api/v1/words" do
    test "returns words for the given language pair", %{conn: conn, user: user} do
      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      Vocabulary.record_word_reveal(user.id, word.id)

      conn = get(conn, ~p"/api/v1/words?language_pair=en-es")
      assert %{"words" => words} = json_response(conn, 200)
      assert length(words) == 1

      assert %{
               "original" => "hello",
               "translation" => "hola",
               "status" => "learning",
               "reveal_count" => 1
             } = hd(words)
    end

    test "returns empty list when no words exist", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/words?language_pair=en-es")
      assert %{"words" => []} = json_response(conn, 200)
    end
  end

  describe "POST /api/v1/words/reveal" do
    test "records a word reveal", %{conn: conn, user: user} do
      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      conn =
        post(conn, ~p"/api/v1/words/reveal", %{"word" => "hello", "language_pair" => "en-es"})

      assert json_response(conn, 200)["success"] == true

      user_word = Vocabulary.get_user_word(user.id, word.id)
      assert user_word.reveal_count == 1
    end

    test "returns 404 for non-existent word", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/words/reveal", %{
          "word" => "nonexistent",
          "language_pair" => "en-es"
        })

      assert %{"error" => "Word not found"} = json_response(conn, 404)
    end
  end

  describe "POST /api/v1/words/replace" do
    test "records a word replacement", %{conn: conn, user: user} do
      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      conn =
        post(conn, ~p"/api/v1/words/replace", %{"word" => "hello", "language_pair" => "en-es"})

      assert json_response(conn, 200)["success"] == true

      user_word = Vocabulary.get_user_word(user.id, word.id)
      assert user_word.replacement_count == 1
    end

    test "returns 404 for non-existent word", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/words/replace", %{
          "word" => "nonexistent",
          "language_pair" => "en-es"
        })

      assert %{"error" => "Word not found"} = json_response(conn, 404)
    end
  end

  describe "POST /api/v1/pagevisit" do
    test "records a page visit", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/pagevisit", %{
          "url" => "https://example.com",
          "words_replaced" => 5,
          "time_spent" => 120
        })

      assert json_response(conn, 200)["success"] == true
    end
  end

  describe "GET /api/v1/stats" do
    test "returns user stats", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/stats")
      assert %{"stats" => stats} = json_response(conn, 200)
      assert is_integer(stats["total_words"])
      assert is_integer(stats["known_words"])
      assert is_integer(stats["learning_words"])
    end
  end

  describe "GET /api/v1/settings" do
    test "returns user settings", %{conn: conn, user: user} do
      conn = get(conn, ~p"/api/v1/settings")
      assert %{"settings" => settings} = json_response(conn, 200)
      assert settings["target_language"] == user.target_language
    end
  end

  describe "PUT /api/v1/settings" do
    test "updates user settings", %{conn: conn} do
      conn =
        put(conn, ~p"/api/v1/settings", %{
          "target_language" => "uz",
          "settings" => %{"replacement_intensity" => 50}
        })

      assert %{"settings" => settings} = json_response(conn, 200)
      assert settings["target_language"] == "uz"
    end
  end

  describe "authentication" do
    test "redirects to login when not authenticated" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_private(:phoenix_endpoint, LinguaswapWeb.Endpoint)
        |> Plug.Test.init_test_session(%{})

      conn = get(conn, ~p"/api/v1/words?language_pair=en-es")
      assert redirected_to(conn) == ~p"/email/log-in"
    end
  end
end
