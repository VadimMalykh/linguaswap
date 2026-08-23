defmodule LinguaswapWeb.DashboardLiveTest do
  use LinguaswapWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Linguaswap.Vocabulary

  setup :register_and_log_in_user

  describe "/dashboard" do
    test "renders the dashboard page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Your Progress"
      assert html =~ "Total Words"
      assert html =~ "Hard"
      assert html =~ "Simple"
      assert html =~ "Easy"
    end

    test "displays stats for user with no words", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/dashboard")
    end

    test "displays correct stats after word interactions", %{conn: conn, user: user} do
      {:ok, word} =
        Vocabulary.create_word(%{
          original_word: "hello",
          target_translation: "hola",
          language_pair: "en-es"
        })

      {:ok, _} = Vocabulary.record_word_reveal(user.id, word.id)

      {:ok, _view, _html} = live(conn, ~p"/dashboard")
    end

    test "shows the learning pool for the user's language pair", %{conn: conn, user: user} do
      for rank <- 1..4 do
        {:ok, _} =
          Vocabulary.create_word(%{
            original_word: "word#{rank}",
            target_translation: "palabra#{rank}",
            language_pair: "en-es",
            frequency_rank: rank
          })
      end

      {:ok, _} = Linguaswap.Accounts.update_user_settings(user, %{"word_budget" => 3})
      Vocabulary.ensure_active_pool(user.id, "en-es")

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Learning Pool"
      assert html =~ "en-es"
      assert html =~ "of 3 active words"
      assert html =~ "1 waiting to be introduced"
    end

    test "shows settings link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Settings"
    end

    test "redirects to login when not authenticated" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})

      assert {:error, {:redirect, %{to: "/email/log-in"}}} = live(conn, ~p"/dashboard")
    end
  end
end
