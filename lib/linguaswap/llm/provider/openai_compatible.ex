defmodule Linguaswap.LLM.Provider.OpenAICompatible do
  @moduledoc """
  Any `/v1/chat/completions` endpoint.

  One adapter covers a lot of ground, because the OpenAI chat-completions shape
  became the lingua franca: OpenAI itself, OpenRouter, Together, Groq, Fireworks,
  a self-hosted vLLM, and Ollama all answer it. Which one you get is decided by
  `:base_url` and `:model` alone.

  This exists so the pipeline is not locked to one vendor. It is not the default
  — the prompts in `Linguaswap.Dictionary` were written and checked against
  Claude — but the seam means changing that is config, not code, and a local
  Ollama makes the whole pipeline free to re-run while iterating on prompts.

  ## Configuration

      config :linguaswap, Linguaswap.LLM,
        provider: Linguaswap.LLM.Provider.OpenAICompatible,
        base_url: "https://api.openai.com/v1/chat/completions",
        api_key: System.get_env("OPENAI_API_KEY"),
        model: "gpt-5-mini"

  For a local Ollama, point `:base_url` at
  `http://localhost:11434/v1/chat/completions` and give it any non-empty
  `:api_key` — it ignores the value but the adapter insists on one rather than
  sending an unauthenticated request to a URL that may not be local at all.

  ## Strict schemas are off by default

  OpenAI's `strict: true` requires every property to be listed in `required`,
  and the dictionary schema deliberately has optional ones: a form key is
  omitted when the target language does not mark that distinction, which is not
  the same as an empty string. So the schema is sent as a non-strict
  `json_schema` and `Linguaswap.Dictionary` re-validates what comes back, which
  it has to do for a generated answer anyway. Set `strict: true` in config if
  you supply a schema that satisfies the stricter rule.
  """

  @behaviour Linguaswap.LLM.Provider

  alias Linguaswap.LLM.Provider

  @default_base_url "https://api.openai.com/v1/chat/completions"
  @default_max_tokens 8_000

  @impl Provider
  def complete(prompt, schema, config) do
    with {:ok, api_key} <- api_key(config),
         {:ok, model} <- model(config) do
      body = %{
        model: model,
        messages: messages(prompt, config[:system]),
        # Reasoning models reject `max_tokens`; this is the name that works on
        # both, and every OpenAI-compatible server has followed suit.
        max_completion_tokens: config[:max_tokens] || @default_max_tokens,
        response_format: %{
          type: "json_schema",
          json_schema: %{
            name: "linguaswap_response",
            strict: config[:strict] || false,
            schema: schema
          }
        }
      }

      request(api_key, body, model, config)
    end
  end

  defp messages(prompt, nil), do: [%{role: "user", content: prompt}]

  defp messages(prompt, system),
    do: [%{role: "system", content: system}, %{role: "user", content: prompt}]

  defp api_key(config) do
    case config[:api_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  # There is no sensible default model here: the right one depends entirely on
  # which of the many compatible services `:base_url` points at, and guessing
  # would mean a confusing 404 instead of a clear configuration error.
  defp model(config) do
    case config[:model] do
      model when is_binary(model) and model != "" -> {:ok, model}
      _ -> {:error, :missing_model}
    end
  end

  defp request(api_key, body, model, config) do
    opts =
      [
        headers: [{"authorization", "Bearer " <> api_key}],
        json: body,
        receive_timeout: config[:receive_timeout] || 120_000,
        retry: :safe_transient
      ]

    opts = if config[:plug], do: Keyword.put(opts, :plug, config[:plug]), else: opts

    case Req.post(config[:base_url] || @default_base_url, opts) do
      {:ok, %{status: 200, body: response}} -> decode(response, model)
      {:ok, %{status: status, body: body}} -> {:error, {:status, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp decode(response, model) do
    choice = response |> Map.get("choices", []) |> List.first() || %{}

    case choice["finish_reason"] do
      # The OpenAI shape's nearest equivalent of a refusal: the content is null
      # and the reason lives in its own field.
      "content_filter" ->
        {:error, {:refusal, "content_filter"}}

      _ ->
        with {:ok, data} <- Provider.decode_json(get_in(choice, ["message", "content"])) do
          {:ok,
           %{
             data: data,
             model: response["model"] || model,
             usage: usage(response["usage"] || %{})
           }}
        end
    end
  end

  defp usage(usage) do
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0

    %{
      # `prompt_tokens` includes the cached ones, so they are subtracted out to
      # leave the same "billed at full rate" number the Anthropic shape reports.
      input_tokens: max(Provider.tokens(usage, "prompt_tokens") - cached, 0),
      output_tokens: Provider.tokens(usage, "completion_tokens"),
      cache_read_input_tokens: if(is_integer(cached), do: cached, else: 0)
    }
  end
end
