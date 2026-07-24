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
      assert html =~ "Known Words"
      assert html =~ "Learning"
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
