defmodule Linguaswap.Verification.Resource do
  @moduledoc """
  Loads and caches the per-language data files the chain reads.

  Two files per language, both built by
  `priv/data/build_verification_data.py` and both optional:

    * `priv/verification/<lang>-paradigms.tsv` — `lemma`, `surface`, UniMorph
      feature bundle, one row per form
    * `priv/verification/<lang>-corpus.txt` — one attested surface per line,
      most frequent first

  A missing file loads as an empty resource rather than raising, because that is
  what makes a verifier degrade to `:unknown` instead of failing a run. A
  language with no data is the ordinary case, not a broken install.

  ## Caching

  Both are read once per language and kept in `:persistent_term`. They are
  read on nearly every claim, never written after load, and shared across every
  process that verifies — which is exactly the shape `:persistent_term` is for,
  and the reason not to hand them to a GenServer that would copy a 34,000-entry
  map into a caller's heap on each lookup. The one cost, a global GC pass per
  write, is paid once per language for the life of the node.
  """

  require Logger

  @dir "verification"

  @doc """
  The paradigm table for a language: `%{lemma => [{surface, tag_set}]}`.

  Empty when the language has no paradigm file, which every verifier reads as
  "no opinion" rather than as "no forms exist".
  """
  def paradigms(language) when is_binary(language) do
    fetch({:paradigms, language}, fn -> load_paradigms(language) end)
  end

  @doc """
  Attested surfaces for a language, as a `MapSet`.

  Empty when the language has no frequency list.
  """
  def corpus(language) when is_binary(language) do
    fetch({:corpus, language}, fn -> load_corpus(language) end)
  end

  @doc """
  Whether a language has a paradigm file with anything in it.
  """
  def paradigms?(language), do: map_size(paradigms(language)) > 0

  @doc """
  Whether a language has a corpus file with anything in it.
  """
  def corpus?(language), do: MapSet.size(corpus(language)) > 0

  @doc """
  Drops the cached resources, so the next read goes back to disk.

  For tests that write a data file and for a `mix` session that rebuilds one.
  """
  def reset do
    for {{__MODULE__, _key} = term, _value} <- :persistent_term.get(),
        do: :persistent_term.erase(term)

    :ok
  end

  @doc """
  Where a language's files live, so a caller can report a missing one.
  """
  def path(kind, language) do
    Application.app_dir(:linguaswap, Path.join("priv", @dir))
    |> Path.join(file_name(kind, language))
  end

  defp file_name(:paradigms, language), do: "#{language}-paradigms.tsv"
  defp file_name(:corpus, language), do: "#{language}-corpus.txt"

  defp fetch(key, load) do
    case :persistent_term.get({__MODULE__, key}, :miss) do
      :miss ->
        value = load.()
        :persistent_term.put({__MODULE__, key}, value)
        value

      value ->
        value
    end
  end

  defp load_paradigms(language) do
    case read(path(:paradigms, language)) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, "\t") do
            [lemma, surface, tags] ->
              entry = {normalize(surface), MapSet.new(String.split(tags, ";", trim: true))}
              Map.update(acc, normalize(lemma), [entry], &[entry | &1])

            _ ->
              acc
          end
        end)

      :error ->
        %{}
    end
  end

  defp load_corpus(language) do
    case read(path(:corpus, language)) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&normalize/1)
        |> MapSet.new()

      :error ->
        MapSet.new()
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        Logger.debug("No verification resource at #{path} (#{:file.format_error(reason)})")
        :error
    end
  end

  @doc """
  The comparison form of a surface.

  Case is folded, whitespace trimmed, and — the reason this is not just
  `String.downcase/1` — the several apostrophes Uzbek is written with are
  collapsed to one. `en-uz.tsv` uses a straight `'` in *bo'lish*, resources use
  `ʻ` or `ʼ`, and without this every Uzbek lookup misses and every tier returns
  `:unknown` for a reason that has nothing to do with the language.

  Unicode is normalised to NFC so that a precomposed *corrió* and a decomposed
  one compare equal; a file written on another machine should not be a source
  of contradictions.
  """
  def normalize(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[\x{2018}\x{2019}\x{02BB}\x{02BC}\x{0027}\x{0060}\x{00B4}]/u, "'")
    |> String.downcase()
    |> :unicode.characters_to_nfc_binary()
  end

  def normalize(_value), do: ""
end
