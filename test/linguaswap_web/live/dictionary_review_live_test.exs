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

      assert html =~ "Dictionary"
      assert html =~ "run"
      assert html =~ "correr"
      assert html =~ "corrió"
      assert html =~ "corriendo"
      # The English frame a reader judges the form in.
      assert html =~ "past tense"
    end

    test "shows which tiers can speak for the pair, and where the floor is", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dictionary/review")

      assert html =~ "1. paradigm"
      assert html =~ "3. corpus"
      assert html =~ "auto-approves at tier 3 or stronger"
    end

    test "switching to a pair with no resources says which tiers are dark", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dictionary/review")

      html =
        view
        |> element("form[phx-change='select-pair']")
        |> render_change(%{"language_pair" => "en-uz"})

      # A floor of 2 with nothing at tiers 1 or 2 is the honest statement that
      # en-uz cannot be checked, and the page has to say so rather than showing
      # a chain that will return :unknown for everything.
      assert html =~ "auto-approves at tier 2 or stronger"
      assert html =~ "line-through"
    end

    test "offers to verify what has been generated but not checked", %{conn: conn} do
      pending_word()

      {:ok, _view, html} = live(conn, ~p"/dictionary/review")

      assert html =~ "Verify 1"
    end

    test "shows what the chain found on an entry it could not settle", %{conn: conn} do
      pending_word(%{
        target_translation: "rendirse",
        forms: %{"past" => "se rindió"},
        verified_at: DateTime.utc_now(:second),
        verification: %{
          "verdict" => "unknown",
          "tier" => nil,
          "floor" => 3,
          "dropped" => [],
          "claims" => %{
            "past" => %{
              "verdict" => "unknown",
              "tier" => nil,
              "verifier" => nil,
              "surface" => "se rindió",
              "attested" => true
            }
          }
        }
      })

      {:ok, _view, html} = live(conn, ~p"/dictionary/review")

      # Why this row in particular is in front of a reader.
      assert html =~ "unknown — no tier had data"
      assert html =~ "se rindió"
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

  describe "the generation panel" do
    # The panel only offers to spend money when there is a key to spend it
    # with, so these tests supply one. Nothing here reaches the network: no run
    # is ever started.
    setup do
      previous = Application.get_env(:linguaswap, Linguaswap.LLM, [])

      Application.put_env(
        :linguaswap,
        Linguaswap.LLM,
        Keyword.put(previous, :api_key, "test-key")
      )

      on_exit(fn -> Application.put_env(:linguaswap, Linguaswap.LLM, previous) end)
    end

    test "offers to generate what is left, with an estimate", %{conn: conn} do
      for rank <- 1..30,
          do:
            Vocabulary.create_word(%{
              original_word: "w#{rank}",
              target_translation: "x#{rank}",
              language_pair: "en-es",
              frequency_rank: rank
            })

      {:ok, _view, html} = live(conn, ~p"/dictionary/review")

      assert html =~ "Generate 20"
      # The button that spends money says roughly what it will spend.
      assert html =~ "about $0.03"
      assert html =~ "30 left to do"
    end

    test "never offers more than there is to do", %{conn: conn} do
      pending_word(%{original_word: "walk", target_translation: "caminar", review_status: nil})

      {:ok, _view, html} = live(conn, ~p"/dictionary/review")

      # One ungenerated entry, so the default choice of 20 is clamped.
      assert html =~ "Generate 1"
    end

    test "says so when nothing is left to generate", %{conn: conn} do
      pending_word()

      {:ok, _view, html} = live(conn, ~p"/dictionary/review")

      assert html =~ "has been generated"
    end

    test "says so when there is no API key, rather than offering a dead button", %{conn: conn} do
      Application.put_env(:linguaswap, Linguaswap.LLM, api_key: nil)
      pending_word(%{original_word: "walk", target_translation: "caminar", review_status: nil})

      {:ok, view, html} = live(conn, ~p"/dictionary/review")

      assert html =~ "No API key is configured"
      refute has_element?(view, "button", "Generate 1")
    end

    test "the button actually starts a run", %{conn: conn} do
      # This is the test that was missing when `Run.start/3`'s two default
      # arguments made the button crash: everything below it was covered, and
      # the click itself was not.
      word =
        pending_word(%{original_word: "walk", target_translation: "caminar", review_status: nil})

      Application.put_env(:linguaswap, Linguaswap.LLM,
        api_key: "k",
        model: "claude-opus-4-8",
        plug: fn conn ->
          entry = %{
            "original_word" => "walk",
            "lemma" => "walk",
            "pos" => "verb",
            "translation" => "caminar",
            "forms" => [%{"feature" => "past", "value" => "caminó"}]
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "model" => "claude-opus-4-8",
              "content" => [
                %{"type" => "text", "text" => Jason.encode!(%{"entries" => [entry]})}
              ],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
            })
          )
        end
      )

      {:ok, view, _html} = live(conn, ~p"/dictionary/review")
      view |> element("button", "Generate 1") |> render_click()

      # The run is a separate process, so give it a moment to finish.
      Process.sleep(300)

      assert Linguaswap.Repo.reload(word).forms == %{"past" => "caminó"}
    end

    test "shows a run started anywhere, not just from this page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dictionary/review")

      # A run belongs to the server: another viewer's run, or one still going
      # from before this page was opened, shows up here too.
      send(view.pid, {:dictionary_run, running_status()})

      html = render(view)
      assert html =~ "Generating en-es — 40 of 100"
      assert html =~ "Stop after this batch"
    end

    test "reports what the last run cost and what it could not do", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dictionary/review")

      send(view.pid, {:dictionary_run, finished_status()})

      html = render(view)
      assert html =~ "38 entries generated"
      assert html =~ "$0.19"
      assert html =~ "2 could not be generated"
      assert html =~ "stopped at the cost cap"
    end

    test "a verification run reports what it approved and what it queued", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dictionary/review")

      send(view.pid, {:dictionary_run, verified_status()})

      html = render(view)
      assert html =~ "31 entries approved"
      assert html =~ "7 went to the queue"
    end
  end

  defp running_status(job \\ :generate) do
    %{
      status: :running,
      running?: true,
      job: job,
      language_pair: "en-es",
      total: 100,
      done: 40,
      generated: 40,
      failed: [],
      result: %{},
      stopped: nil,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      spent_usd: 0.0
    }
  end

  defp finished_status do
    %{
      running_status()
      | status: :finished,
        running?: false,
        done: 40,
        generated: 38,
        failed: [{"a", :not_returned}, {"b", :not_returned}],
        stopped: :cost_cap_reached,
        finished_at: DateTime.utc_now(),
        spent_usd: 0.1875
    }
  end

  defp verified_status do
    %{
      running_status(:verify)
      | status: :finished,
        running?: false,
        generated: 31,
        result: %{verified: 38, approved: 31, queued: 7, dropped: [], stopped: nil},
        stopped: nil,
        finished_at: DateTime.utc_now(),
        spent_usd: 0.02
    }
  end

  test "the dashboard links to the queue with its size", %{conn: conn} do
    pending_word()

    {:ok, _view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Review generated forms"
    assert html =~ "/dictionary/review"
  end
end
