defmodule Linguaswap.LLM.Provider do
  @moduledoc """
  The contract every model backend implements.

  `Linguaswap.LLM` owns the parts that are the same whoever answers — the
  budget, the rate limit, the retry policy — and a provider owns the parts that
  are not: the URL, the auth header, the request body, and where in the reply
  the JSON is. Swapping providers is then a one-line config change rather than
  a rewrite of `Linguaswap.Dictionary`.

  There is exactly one callback because the pipeline only ever asks one kind of
  question: here is a prompt and a JSON schema, give me an object back.

  ## Implementing one

  `config` is the `Linguaswap.LLM` keyword list with any per-call overrides
  already merged, so a provider reads its own keys (`:api_key`, `:model`,
  `:base_url`, whatever it needs) straight out of it.

  On success return the decoded object, the model that actually answered, and
  the usage report **normalised to these keys**, so `Linguaswap.LLM.Budget` can
  price any provider without knowing which one it was:

      {:ok, %{
        data: %{"entries" => [...]},
        model: "claude-opus-5",
        usage: %{input_tokens: 812, output_tokens: 940, cache_read_input_tokens: 0}
      }}

  On failure return `{:error, reason}`. Use the shared reasons below where they
  fit — callers match on them to decide whether a run should stop or carry on:

    * `:missing_api_key` — nothing is configured; the run cannot continue
    * `{:status, code, body}` — the provider answered, unhappily
    * `{:refusal, category}` — the model declined
    * `{:invalid_json, text}` — the reply was not the object we asked for
  """

  @type usage :: %{
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          optional(:cache_read_input_tokens) => non_neg_integer()
        }

  @type result :: %{data: map(), model: String.t(), usage: usage()}

  @callback complete(prompt :: String.t(), schema :: map(), config :: keyword()) ::
              {:ok, result()} | {:error, term()}

  @doc """
  Decodes the JSON object a model returned as text.

  Every provider gets asked for a JSON object and hands back a string, so the
  last step is the same for all of them.
  """
  def decode_json(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, data} when is_map(data) -> {:ok, data}
      _ -> {:error, {:invalid_json, text}}
    end
  end

  def decode_json(other), do: {:error, {:invalid_json, inspect(other)}}

  @doc """
  Reads a token count out of a provider's usage report.

  Providers disagree about both the key names and what they do when a count is
  absent, so this is deliberately forgiving: anything that is not a positive
  integer counts as zero. A mis-read usage field should not fail a request that
  already succeeded — it should only mean the run's spend is under-counted,
  which the cost cap then catches later rather than never.
  """
  def tokens(usage, key) when is_map(usage) do
    case Map.get(usage, key) do
      count when is_integer(count) and count > 0 -> count
      _ -> 0
    end
  end

  def tokens(_usage, _key), do: 0
end
