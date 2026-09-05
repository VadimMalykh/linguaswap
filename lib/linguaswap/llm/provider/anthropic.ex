defmodule Linguaswap.LLM.Provider.Anthropic do
  @moduledoc """
  The Claude Messages API, over `Req`.

  The default provider, and the one the prompts in `Linguaswap.Dictionary` were
  written against. Elixir has no official Anthropic SDK, so this speaks the
  HTTP API directly.

  Three things worth knowing about the request it builds:

    * **Structured outputs.** `output_config.format` pins the reply to the JSON
      schema, so the importer parses rather than scrapes. Without it a model
      that decides to be helpful and add a sentence of explanation breaks the
      run.
    * **Effort is the cost dial.** Thinking is on by default on Claude Opus 5
      and thinking tokens bill as output, which makes them the largest single
      line in a generation run. `effort: :low` is the setting for bulk
      lexicography — the work is recall, not reasoning — and it is what the
      default config uses. Set it to `nil` to leave the model at its own
      default.
    * **No streaming.** Batches are small and nobody is watching the output, so
      the simpler non-streaming shape is right; `max_tokens` stays well inside
      the request timeout for the same reason.

  ## Configuration

      config :linguaswap, Linguaswap.LLM,
        provider: Linguaswap.LLM.Provider.Anthropic,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        model: "claude-opus-5",
        effort: :low
  """

  @behaviour Linguaswap.LLM.Provider

  alias Linguaswap.LLM.Provider

  @endpoint "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"

  @default_model "claude-opus-5"
  @default_max_tokens 8_000

  @impl Provider
  def complete(prompt, schema, config) do
    with {:ok, api_key} <- api_key(config) do
      model = config[:model] || @default_model

      body =
        %{
          model: model,
          max_tokens: config[:max_tokens] || @default_max_tokens,
          messages: [%{role: "user", content: prompt}],
          output_config: %{format: %{type: "json_schema", schema: schema}}
        }
        |> put_system(config[:system])
        |> put_effort(config[:effort])

      request(api_key, body, model, config)
    end
  end

  defp put_system(body, nil), do: body
  defp put_system(body, system), do: Map.put(body, :system, system)

  defp put_effort(body, nil), do: body

  defp put_effort(body, effort) do
    update_in(body, [:output_config], &Map.put(&1, :effort, to_string(effort)))
  end

  defp api_key(config) do
    case config[:api_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp request(api_key, body, model, config) do
    opts =
      [
        headers: [{"x-api-key", api_key}, {"anthropic-version", @api_version}],
        json: body,
        receive_timeout: config[:receive_timeout] || 120_000,
        # A 429 or a 5xx is worth another try; a 400 is a bug in the request and
        # retrying it only spends the clock.
        retry: :safe_transient
      ]

    # Set in the test environment to answer requests in-process instead of over
    # the network, so the suite never needs a key or a connection.
    opts = if config[:plug], do: Keyword.put(opts, :plug, config[:plug]), else: opts

    case Req.post(config[:base_url] || @endpoint, opts) do
      {:ok, %{status: 200, body: response}} -> decode(response, model)
      {:ok, %{status: status, body: body}} -> {:error, {:status, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  # A refusal is an ordinary 200, so `stop_reason` is checked before the content
  # is read — otherwise a declined request looks like an empty answer.
  defp decode(%{"stop_reason" => "refusal"} = response, _model) do
    {:error, {:refusal, get_in(response, ["stop_details", "category"])}}
  end

  defp decode(response, model) do
    text =
      response
      |> Map.get("content", [])
      |> Enum.find_value("", fn
        %{"type" => "text", "text" => text} -> text
        _ -> nil
      end)

    with {:ok, data} <- Provider.decode_json(text) do
      {:ok,
       %{
         data: data,
         model: response["model"] || model,
         usage: usage(response["usage"] || %{})
       }}
    end
  end

  defp usage(usage) do
    %{
      # Cache writes are billed as input, so they are counted as input here and
      # the cheaper cache reads are kept separate.
      input_tokens:
        Provider.tokens(usage, "input_tokens") +
          Provider.tokens(usage, "cache_creation_input_tokens"),
      output_tokens: Provider.tokens(usage, "output_tokens"),
      cache_read_input_tokens: Provider.tokens(usage, "cache_read_input_tokens")
    }
  end
end
