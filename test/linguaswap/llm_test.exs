defmodule Linguaswap.LLMTest do
  # Not async: the client is configured through the application environment,
  # which is global, so two of these running at once would swap each other's
  # stub out from under them.
  use ExUnit.Case, async: false

  alias Linguaswap.LLM
  alias Linguaswap.LLM.Budget
  alias Linguaswap.LLM.Provider

  @schema %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}

  # The client is exercised against a plug rather than the network: `Req`
  # answers in-process, so the suite needs neither a key nor a connection while
  # still going through the real request-building and response-parsing code.
  setup context do
    {:ok, budget} =
      Budget.start_link(
        name: :"budget_#{:erlang.unique_integer([:positive])}",
        config: [
          requests_per_minute: context[:requests_per_minute] || 100,
          cost_cap_usd: context[:cost_cap_usd] || 100.0
        ]
      )

    %{budget: budget}
  end

  defp stub(response, status \\ 200) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:request, Jason.decode!(body), Plug.Conn.get_req_header(conn, "x-api-key")})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(response))
    end
  end

  defp configure(plug, extra \\ []) do
    previous = Application.get_env(:linguaswap, LLM, [])

    Application.put_env(
      :linguaswap,
      LLM,
      Keyword.merge([api_key: "test-key", model: "claude-opus-5", plug: plug], extra)
    )

    on_exit(fn -> Application.put_env(:linguaswap, LLM, previous) end)
  end

  defp message(text, usage \\ %{"input_tokens" => 10, "output_tokens" => 5}) do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => usage
    }
  end

  describe "complete/3" do
    test "sends the prompt and returns the decoded JSON object", %{budget: budget} do
      configure(stub(message(~s({"ok": true}))))

      assert {:ok, %{"ok" => true}} =
               LLM.complete("do the thing", @schema, budget: budget, system: "be helpful")

      assert_received {:request, body, ["test-key"]}
      assert body["model"] == "claude-opus-5"
      assert body["system"] == "be helpful"
      assert body["messages"] == [%{"role" => "user", "content" => "do the thing"}]
      # Structured outputs, so the reply is parsed rather than scraped.
      assert body["output_config"]["format"]["type"] == "json_schema"
      assert body["output_config"]["format"]["schema"] == @schema
    end

    test "sends the configured effort, which is what bounds thinking spend", %{budget: budget} do
      configure(stub(message(~s({"ok": true}))), effort: :low)

      assert {:ok, _} = LLM.complete("hello", @schema, budget: budget)

      assert_received {:request, body, _}
      assert body["output_config"]["effort"] == "low"
    end

    test "refuses to build a request without an API key", %{budget: budget} do
      configure(stub(message(~s({"ok": true}))), api_key: nil)

      assert {:error, :missing_api_key} = LLM.complete("hello", @schema, budget: budget)
      refute_received {:request, _, _}
    end

    test "reports a non-200 rather than guessing at the body", %{budget: budget} do
      configure(stub(%{"error" => %{"message" => "bad request"}}, 400))

      assert {:error, {:status, 400, body}} = LLM.complete("hello", @schema, budget: budget)
      assert body["error"]["message"] == "bad request"
    end

    test "reads a refusal as a refusal, not as an empty answer", %{budget: budget} do
      configure(
        stub(%{
          "content" => [],
          "stop_reason" => "refusal",
          "stop_details" => %{"type" => "refusal", "category" => "cyber"},
          "usage" => %{}
        })
      )

      assert {:error, {:refusal, "cyber"}} = LLM.complete("hello", @schema, budget: budget)
    end

    test "reports text that is not JSON", %{budget: budget} do
      configure(stub(message("Sure! Here you go.")))

      assert {:error, {:invalid_json, "Sure! Here you go."}} =
               LLM.complete("hello", @schema, budget: budget)
    end

    test "charges the budget what the response says it cost", %{budget: budget} do
      configure(
        stub(message(~s({"ok": true}), %{"input_tokens" => 1_000_000, "output_tokens" => 0}))
      )

      assert {:ok, _} = LLM.complete("hello", @schema, budget: budget)

      # A million input tokens at the Opus 5 list price.
      assert %{spent_usd: spent, requests: 1} = Budget.stats(budget)
      assert_in_delta spent, 5.0, 0.001
    end

    @tag cost_cap_usd: 0.000_001
    test "stops once the run has spent its allowance", %{budget: budget} do
      configure(
        stub(message(~s({"ok": true}), %{"input_tokens" => 100_000, "output_tokens" => 100_000}))
      )

      assert {:ok, _} = LLM.complete("hello", @schema, budget: budget)
      assert {:error, :cost_cap_reached} = LLM.complete("hello again", @schema, budget: budget)
    end
  end

  describe "Budget" do
    @tag requests_per_minute: 1
    test "asks a caller to wait rather than failing it", %{budget: budget} do
      assert :ok = Budget.checkout(budget)
      assert {:wait, ms} = Budget.checkout(budget)
      # Within the one-minute window, and never zero — a zero would busy-loop.
      assert ms > 0 and ms <= 60_001
    end

    test "prices a request from the usage the API reports" do
      usage = %{"input_tokens" => 1_000_000, "output_tokens" => 1_000_000}

      assert_in_delta Budget.cost("claude-opus-5", usage), 30.0, 0.001
      assert_in_delta Budget.cost("claude-haiku-4-5", usage), 6.0, 0.001
      # A model with no price is charged nothing rather than a guess.
      assert Budget.cost("some-new-model", usage) == 0.0
    end

    test "treats a malformed usage report as free rather than raising" do
      assert Budget.cost("claude-opus-5", %{}) == 0.0
      assert Budget.cost("claude-opus-5", nil) == 0.0
      assert Budget.cost("claude-opus-5", %{"input_tokens" => "lots"}) == 0.0
    end
  end

  describe "provider seam" do
    defmodule StubProvider do
      @behaviour Linguaswap.LLM.Provider

      @impl true
      def complete(prompt, _schema, config) do
        send(self(), {:stub_provider, prompt, config[:model]})

        {:ok,
         %{
           data: %{"answered_by" => "stub"},
           model: "stub-model",
           usage: %{input_tokens: 1_000_000, output_tokens: 0}
         }}
      end
    end

    test "any module implementing the behaviour can answer", %{budget: budget} do
      # The point of the seam: nothing above this call knows or cares who
      # answered, and swapping the answerer is one config key.
      configure(stub(message(~s({"ok": true}))), provider: StubProvider, model: "stub-model")

      assert {:ok, %{"answered_by" => "stub"}} = LLM.complete("hello", @schema, budget: budget)
      assert_received {:stub_provider, "hello", "stub-model"}
      # No HTTP happened at all.
      refute_received {:request, _, _}
    end

    test "a provider's usage is priced whoever it came from", %{budget: budget} do
      configure(stub(message(~s({"ok": true}))), provider: StubProvider, model: "stub-model")

      LLM.complete("hello", @schema, budget: budget)

      # "stub-model" has no configured price, so it is billed at zero rather
      # than at a guess — the run keeps going, the cap is just not moved.
      assert %{spent_usd: +0.0, requests: 1} = Budget.stats(budget)
    end

    test "reports which provider is in force" do
      configure(stub(message(~s({"ok": true}))), provider: StubProvider)
      assert LLM.provider() == StubProvider
    end
  end

  describe "OpenAI-compatible provider" do
    defp openai_stub(response, status \\ 200) do
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          self(),
          {:request, Jason.decode!(body), Plug.Conn.get_req_header(conn, "authorization")}
        )

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(response))
      end
    end

    defp chat_completion(
           content,
           usage \\ %{"prompt_tokens" => 10, "completion_tokens" => 5},
           model \\ "gpt-5-mini"
         ) do
      %{
        "model" => model,
        "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => content}}],
        "usage" => usage
      }
    end

    setup do
      previous = Application.get_env(:linguaswap, LLM, [])

      on_exit(fn -> Application.put_env(:linguaswap, LLM, previous) end)
      :ok
    end

    defp configure_openai(plug, extra \\ []) do
      Application.put_env(
        :linguaswap,
        LLM,
        Keyword.merge(
          [
            provider: Provider.OpenAICompatible,
            api_key: "test-key",
            model: "gpt-5-mini",
            base_url: "https://api.openai.com/v1/chat/completions",
            plug: plug
          ],
          extra
        )
      )
    end

    test "speaks the chat-completions shape", %{budget: budget} do
      configure_openai(openai_stub(chat_completion(~s({"ok": true}))))

      assert {:ok, %{"ok" => true}} =
               LLM.complete("do the thing", @schema, budget: budget, system: "be helpful")

      assert_received {:request, body, ["Bearer test-key"]}
      assert body["model"] == "gpt-5-mini"

      assert body["messages"] == [
               %{"role" => "system", "content" => "be helpful"},
               %{"role" => "user", "content" => "do the thing"}
             ]

      assert body["response_format"]["type"] == "json_schema"
      assert body["response_format"]["json_schema"]["schema"] == @schema
      # Optional properties in the dictionary schema make strict mode illegal
      # there, so it is off unless a caller opts in.
      assert body["response_format"]["json_schema"]["strict"] == false
      # Reasoning models reject `max_tokens`.
      assert body["max_completion_tokens"]
    end

    test "normalises usage so the same budget prices it", %{budget: budget} do
      configure_openai(
        openai_stub(
          chat_completion(
            ~s({"ok": true}),
            %{"prompt_tokens" => 1_000_000, "completion_tokens" => 1_000_000},
            # Priced by the model that actually answered, which is what the
            # response says it was — not by what the config asked for.
            "claude-opus-5"
          )
        ),
        model: "claude-opus-5"
      )

      assert {:ok, _} = LLM.complete("hello", @schema, budget: budget)

      # Priced with the same table and the same arithmetic as the Anthropic
      # provider: the budget never learns who answered.
      assert %{spent_usd: spent} = Budget.stats(budget)
      assert_in_delta spent, 30.0, 0.001
    end

    test "says so when no model is configured", %{budget: budget} do
      configure_openai(openai_stub(chat_completion(~s({"ok": true}))), model: nil)

      # There is no sensible default: the right model depends entirely on which
      # compatible service the base URL points at.
      assert {:error, :missing_model} = LLM.complete("hello", @schema, budget: budget)
    end

    test "reads a content filter as a refusal", %{budget: budget} do
      configure_openai(
        openai_stub(%{
          "model" => "gpt-5-mini",
          "choices" => [%{"finish_reason" => "content_filter", "message" => %{"content" => nil}}],
          "usage" => %{}
        })
      )

      assert {:error, {:refusal, "content_filter"}} =
               LLM.complete("hello", @schema, budget: budget)
    end
  end
end
