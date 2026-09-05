defmodule Mix.Tasks.Linguaswap.ImportWords do
  @shortdoc "Imports dictionary entries from a TSV file"

  @moduledoc """
  Imports dictionary entries for one language pair from a tab-separated file.

      mix linguaswap.import_words priv/data/en-es.tsv

  The language pair is taken from the file name (`en-es.tsv`) unless
  `--language-pair` is given.

  ## File format

  Blank lines and lines starting with `#` are ignored. Columns:

      original_word <TAB> target_translation [<TAB> frequency_rank [<TAB> pos]]

  When `frequency_rank` is omitted the row's position in the file is used, so a
  plain frequency-ordered list imports as-is. `difficulty_score` is derived from
  the rank band — the field is not something a source list usually carries.

  ## Options

    * `--language-pair` - overrides the pair inferred from the file name
    * `--source` - value stored in `words.source` (default: `import`)
    * `--dry-run` - parse and report without writing to the database
    * `--prune` - delete entries for this pair that the file no longer carries
    * `--generate` - fill in part of speech and target-side inflected forms
      with the LLM after importing
    * `--generate-limit` - how many entries to generate for (default: all)

  ## Generating the missing data

  A TSV carries a translation and a rank; it does not carry the target's past
  tense. `--generate` runs `Linguaswap.Dictionary.generate/2` over the entries
  that have never been generated for, in frequency order:

      mix linguaswap.import_words priv/data/en-es.tsv --generate

  It needs `ANTHROPIC_API_KEY` in the environment and it spends money, so the
  run is bounded twice over: `--generate-limit` caps how much is attempted, and
  the configured cost cap stops the run when it has spent its allowance.
  Generated forms land as `pending` and are not served until a human approves
  them on the dashboard.

  ## Rebuilding a dictionary

  The import upserts, so entries dropped from the file stay in the database and
  keep competing for frontier slots. `--prune` clears them:

      mix linguaswap.import_words priv/data/en-es.tsv --prune

  Entries a user has progress on are never deleted — `user_words` cascades, so
  pruning one would take that user's history with it. Those are reported for a
  human to resolve.
  """

  use Mix.Task

  alias Linguaswap.Dictionary
  alias Linguaswap.LLM
  alias Linguaswap.Vocabulary
  alias Linguaswap.Vocabulary.Word

  # Frequency bands → difficulty. The top of a frequency list is the everyday
  # core of the language; the tail is where the genuinely hard words live.
  @difficulty_bands [{500, 1}, {2_000, 2}, {5_000, 3}, {15_000, 4}]
  @max_difficulty 5

  @impl Mix.Task
  def run(args) do
    {opts, paths} =
      OptionParser.parse!(args,
        strict: [
          language_pair: :string,
          source: :string,
          dry_run: :boolean,
          prune: :boolean,
          generate: :boolean,
          generate_limit: :integer
        ]
      )

    path =
      case paths do
        [path] -> path
        _ -> Mix.raise("expected exactly one file path, got: #{inspect(paths)}")
      end

    language_pair = opts[:language_pair] || infer_language_pair(path)

    unless language_pair in Word.language_pairs() do
      Mix.raise(
        "unsupported language pair #{inspect(language_pair)}; " <>
          "known pairs: #{Enum.join(Word.language_pairs(), ", ")}"
      )
    end

    rows = path |> File.read!() |> parse(language_pair, opts[:source] || "import")

    if opts[:dry_run] do
      Mix.shell().info("[dry run] #{length(rows)} entries parsed for #{language_pair}")
      report_sample(rows)
    else
      Mix.Task.run("app.start")
      {ok, failed} = import_rows(rows)

      Mix.shell().info("Imported #{ok} #{language_pair} entries from #{path}")

      unless failed == [] do
        Mix.shell().error("#{length(failed)} entries failed:")
        Enum.each(failed, fn {word, message} -> Mix.shell().error("  #{word}: #{message}") end)
      end

      if opts[:prune], do: prune(language_pair, rows)
      if opts[:generate], do: generate(language_pair, opts)
    end
  end

  defp generate(language_pair, opts) do
    unless LLM.configured?() do
      Mix.raise("ANTHROPIC_API_KEY is not set, so there is nothing to generate with")
    end

    pending = length(Dictionary.entries_needing_generation(language_pair, opts[:generate_limit]))
    Mix.shell().info("Generating forms for #{pending} #{language_pair} entries...")

    result =
      Dictionary.generate(language_pair,
        limit: opts[:generate_limit],
        on_batch: fn {done, total} -> Mix.shell().info("  #{done}/#{total}") end
      )

    Mix.shell().info("Generated #{result.generated} entries")

    unless result.failed == [] do
      Mix.shell().error("#{length(result.failed)} entries could not be generated:")

      Enum.each(result.failed, fn {word, reason} ->
        Mix.shell().error("  #{word}: #{describe_failure(reason)}")
      end)
    end

    if result.stopped do
      Mix.shell().error("Run stopped: #{describe_failure(result.stopped)}")
    end

    stats = Dictionary.review_stats(language_pair)

    Mix.shell().info(
      "#{stats.pending} entries are waiting for review on the dashboard " <>
        "(#{stats.approved} approved, #{stats.rejected} rejected)"
    )
  end

  defp describe_failure(%Ecto.Changeset{} = changeset), do: describe_errors(changeset)
  defp describe_failure(:missing_api_key), do: "ANTHROPIC_API_KEY is not set"
  defp describe_failure(:cost_cap_reached), do: "the run reached its cost cap"
  defp describe_failure(:not_returned), do: "the model did not return this entry"

  defp describe_failure(:first_batch_failed),
    do: "nothing in the first batch generated, so the rest was not attempted"

  defp describe_failure({:refusal, category}),
    do: "the model declined the request (#{category})"

  defp describe_failure(reason), do: inspect(reason)

  @doc """
  Parses TSV content into word attribute maps.

  Public so the format stays under test without touching the database.
  """
  def parse(content, language_pair, source \\ "import") do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.with_index(1)
    |> Enum.map(fn {line, position} -> row(line, position, language_pair, source) end)
  end

  defp row(line, position, language_pair, source) do
    [original, translation | rest] = String.split(line, "\t")
    rank = rest |> Enum.at(0) |> parse_rank(position)

    %{
      original_word: String.trim(original),
      target_translation: String.trim(translation),
      language_pair: language_pair,
      frequency_rank: rank,
      difficulty_score: difficulty_for_rank(rank),
      pos: rest |> Enum.at(1) |> blank_to_nil(),
      source: source
    }
  end

  defp parse_rank(nil, position), do: position

  defp parse_rank(value, position) do
    case value |> String.trim() |> Integer.parse() do
      {rank, ""} when rank > 0 -> rank
      _ -> position
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  Maps a frequency rank onto a 1..#{@max_difficulty} difficulty score.
  """
  def difficulty_for_rank(rank) when is_integer(rank) and rank > 0 do
    Enum.find_value(@difficulty_bands, @max_difficulty, fn {ceiling, score} ->
      rank <= ceiling && score
    end)
  end

  defp import_rows(rows) do
    Enum.reduce(rows, {0, []}, fn attrs, {ok, failed} ->
      case Vocabulary.upsert_word(attrs) do
        {:ok, _word} ->
          {ok + 1, failed}

        {:error, changeset} ->
          {ok, failed ++ [{attrs.original_word, describe_errors(changeset)}]}
      end
    end)
  end

  defp prune(language_pair, rows) do
    keep = Enum.map(rows, & &1.original_word)
    %{deleted: deleted, retained: retained} = Vocabulary.prune_words(language_pair, keep)

    Mix.shell().info("Pruned #{deleted} #{language_pair} entries no longer in the file")

    unless retained == [] do
      Mix.shell().error(
        "#{length(retained)} stale #{language_pair} entries kept because users have " <>
          "progress on them — resolve by hand:"
      )

      Enum.each(retained, fn word ->
        Mix.shell().error(
          "  #{word.original_word} -> #{word.target_translation} " <>
            "(id #{word.id}, rank #{inspect(word.frequency_rank)})"
        )
      end)
    end
  end

  defp describe_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp report_sample(rows) do
    rows
    |> Enum.take(3)
    |> Enum.each(fn row ->
      Mix.shell().info(
        "  #{row.original_word} → #{row.target_translation} " <>
          "(rank #{row.frequency_rank}, difficulty #{row.difficulty_score})"
      )
    end)
  end

  defp infer_language_pair(path) do
    path |> Path.basename() |> Path.rootname()
  end
end
