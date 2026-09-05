defmodule LinguaswapWeb.DictionaryReviewLiveTest do
  use LinguaswapWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Linguaswap.Repo
  alias Linguaswap.Vocabulary
  alias Linguaswap.Vocabulary.Word

  setup :register_and_log_in_user

  defp pending_word(attrs \\ %{}) do
    {:ok, word} =
      attrs
      |> Enum.into(%{
        original_word: "run",
        target_translation: "correr",
        language_pair: "en-es",
        frequency_rank: 1,
        pos: "verb",
        forms: %{"past" => "corrió", "gerund" => "corriendo"},
        review_status: "pending"
      })
      |> Vocabulary.create_word()

    word
  end

  describe "/dictionary/review" do
    test "lists what a generated entry proposes", %{conn: conn} do
      pending_word()

      {:ok, _view, html} = live(conn, ~p"/dictionary/review")

      assert html =~ "Review Generated Forms"
      assert html =~ "run"
      assert html =~ "correr"
      assert html =~ "corrió"
      assert html =~ "corriendo"
      # The English frame a reader judges the form in.
      assert html =~ "past tense"
    end

    test "says so when nothing is waiting", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dictionary/review")

      assert html =~ "Nothing is waiting for review"
    end

    test "leaves hand-authored entries out of the queue", %{conn: conn} do
      pending_word(%{original_word: "walk", target_translation: "caminar", review_status: nil})

      {:ok, _view, html} = live(conn, ~p"/dictionary/review")

      assert html =~ "Nothing is waiting for review"
    end

    test "approving an entry starts it being served", %{conn: conn} do
      word = pending_word()

      {:ok, view, _html} = live(conn, ~p"/dictionary/review")
      html = view |> element("#entry-#{word.id} button", "Approve") |> render_click()

      assert html =~ "Nothing is waiting for review"

      approved = Repo.reload(word)
      assert approved.review_status == "approved"
      assert Word.servable_forms(approved) == %{"past" => "corrió", "gerund" => "corriendo"}
    end

    test "rejecting an entry clears the forms but keeps the word", %{conn: conn} do
      word = pending_word()

      {:ok, view, _html} = live(conn, ~p"/dictionary/review")
      view |> element("#entry-#{word.id} button", "Reject") |> render_click()

      rejected = Repo.reload(word)
      assert rejected.review_status == "rejected"
      assert rejected.forms == %{}
      assert rejected.target_translation == "correr"
    end

    test "only shows the queue for the user's own language pair", %{conn: conn, user: user} do
      {:ok, user} = Linguaswap.Accounts.update_user_target_language(user, "uz")
      pending_word(%{language_pair: "en-es"})

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/dictionary/review")

      assert html =~ "en-uz"
      assert html =~ "Nothing is waiting for review"
    end
  end

  test "the dashboard links to the queue with its size", %{conn: conn} do
    pending_word()

    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Review generated forms"
    assert html =~ "/dictionary/review"
  end
end
