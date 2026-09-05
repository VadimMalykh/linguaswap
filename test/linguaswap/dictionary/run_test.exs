defmodule Linguaswap.Dictionary.RunTest do
  # Not async: the run process is named and the LLM client is configured
  # through the application environment.
  use Linguaswap.DataCase, async: false

  alias Linguaswap.Dictionary.Run
  alias Linguaswap.LLM
  alias Linguaswap.Vocabulary

  setup do
    # A run of this process per test, so one test's run is not another's.
    {:ok, pid} = Run.start_link(name: :"run_#{System.unique_integer([:positive])}")
    %{run: pid}
  end

  defp word(rank) do
    {:ok, word} =
      Vocabulary.create_word(%{
        original_word: "w#{rank}",
        target_translation: "x#{rank}",
        language_pair: "en-es",
        frequency_rank: rank
      })

    word
  end

  # Answers with whatever entries were asked for, so a run completes.
  defp stub_llm(opts \\ []) do
    previous = Application.get_env(:linguaswap, LLM, [])
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      prompt = body |> Jason.decode!() |> get_in(["messages", Access.at(0), "content"])
      send(test, {:batch, prompt})

      if delay = opts[:delay], do: Process.sleep(delay)

      entries =
        Regex.scan(~r/^- (\S+)/m, prompt)
        |> Enum.map(fn [_, word] ->
          %{
            "original_word" => word,
            "lemma" => word,
            "pos" => "verb",
            "translation" => "t-#{word}",
            "forms" => [%{"feature" => "past", "value" => "p-#{word}"}]
          }
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "model" => "claude-opus-4-8",
          "content" => [%{"type" => "text", "text" => Jason.encode!(%{"entries" => entries})}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 1000, "output_tokens" => 1000}
        })
      )
    end

    Application.put_env(:linguaswap, LLM, api_key: "k", model: "claude-opus-4-8", plug: plug)
    on_exit(fn -> Application.put_env(:linguaswap, LLM, previous) end)
  end

  defp await_finish(run, tries \\ 100) do
    case Run.status(run) do
      %{status: :finished} = status -> status
      _ when tries > 0 -> Process.sleep(20) && await_finish(run, tries - 1)
      status -> flunk("run did not finish: #{inspect(status)}")
    end
  end

  test "runs to completion and reports what it cost", %{run: run} do
    for rank <- 1..3, do: word(rank)
    stub_llm()

    assert :ok = Run.start(run, "en-es")
    status = await_finish(run)

    assert status.generated == 3
    assert status.failed == []
    assert status.language_pair == "en-es"
    # Charged at the Opus 4.8 rate from the usage the stub reported.
    assert_in_delta status.spent_usd, 0.03, 0.001

    assert Vocabulary.get_word_by_original("w1", "en-es").forms == %{"past" => "p-w1"}
  end

  test "refuses a second run rather than paying twice", %{run: run} do
    for rank <- 1..3, do: word(rank)
    stub_llm(delay: 200)

    assert :ok = Run.start(run, "en-es")
    # Two concurrent runs would race for the same unqueued entries and generate
    # them — and bill for them — twice.
    assert {:error, :already_running} = Run.start(run, "en-es")

    await_finish(run)
  end

  test "will not start without an API key", %{run: run} do
    word(1)
    previous = Application.get_env(:linguaswap, LLM, [])
    Application.put_env(:linguaswap, LLM, api_key: nil)
    on_exit(fn -> Application.put_env(:linguaswap, LLM, previous) end)

    assert {:error, :missing_api_key} = Run.start(run, "en-es")
    assert Run.status(run).status == :idle
  end

  test "cancelling keeps the work already paid for", %{run: run} do
    for rank <- 1..10, do: word(rank)
    stub_llm(delay: 100)

    assert :ok = Run.start(run, "en-es", batch_size: 2)
    # Cancel while the first batch is in flight.
    Process.sleep(50)
    assert :ok = Run.cancel(run)

    status = await_finish(run)

    assert status.stopped == :cancelled
    # The batch that was already running finished and its entries were kept —
    # they had been paid for either way.
    assert status.generated > 0
    assert status.generated < 10
  end

  test "cancelling when nothing is running says so", %{run: run} do
    assert {:error, :not_running} = Run.cancel(run)
  end

  test "broadcasts progress to whoever is watching", %{run: run} do
    for rank <- 1..4, do: word(rank)
    stub_llm()
    Run.subscribe()

    Run.start(run, "en-es", batch_size: 2)
    await_finish(run)

    # A subscriber sees the run start and finish without polling, which is what
    # lets a second browser tab follow a run it did not start.
    assert_received {:dictionary_run, %{status: :running, total: 4}}
    assert_received {:dictionary_run, %{status: :finished, generated: 4}}
  end

  test "estimates a run's cost before it happens" do
    # Enough to put a number on the button; the real figure comes from the
    # budget afterwards.
    assert Run.estimate_cost(0) == 0.0
    assert_in_delta Run.estimate_cost(100), 0.15, 0.001
  end
end
