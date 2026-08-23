defmodule Mix.Tasks.Linguaswap.ImportWordsTest do
  use Linguaswap.DataCase

  alias Linguaswap.Vocabulary
  alias Mix.Tasks.Linguaswap.ImportWords

  describe "parse/3" do
    test "skips comments and blank lines" do
      content = """
      # original_word\ttarget_translation\tfrequency_rank
      the\tel\t1

      be\tser\t2
      """

      assert [the, be] = ImportWords.parse(content, "en-es")
      assert the.original_word == "the"
      assert the.target_translation == "el"
      assert the.frequency_rank == 1
      assert be.frequency_rank == 2
    end

    test "falls back to file position when no rank column is present" do
      content = "the\tel\nbe\tser\nto\ta\n"

      assert [_, _, to] = ImportWords.parse(content, "en-es")
      assert to.frequency_rank == 3
    end

    test "falls back to file position when the rank is not a positive integer" do
      content = "the\tel\tn/a\n"

      assert [row] = ImportWords.parse(content, "en-es")
      assert row.frequency_rank == 1
    end

    test "reads an optional part-of-speech column" do
      content = "run\tcorrer\t99\tverb\nthe\tel\t1\n"

      assert [run, the] = ImportWords.parse(content, "en-es")
      assert run.pos == "verb"
      assert the.pos == nil
    end

    test "tags rows with the language pair and source" do
      assert [row] = ImportWords.parse("the\tel\t1\n", "en-uz", "seed")
      assert row.language_pair == "en-uz"
      assert row.source == "seed"
    end
  end

  describe "difficulty_for_rank/1" do
    test "maps frequency bands onto increasing difficulty" do
      assert ImportWords.difficulty_for_rank(1) == 1
      assert ImportWords.difficulty_for_rank(500) == 1
      assert ImportWords.difficulty_for_rank(501) == 2
      assert ImportWords.difficulty_for_rank(2_000) == 2
      assert ImportWords.difficulty_for_rank(5_000) == 3
      assert ImportWords.difficulty_for_rank(15_000) == 4
      assert ImportWords.difficulty_for_rank(15_001) == 5
    end
  end

  describe "shipped data files" do
    test "every seed file parses and imports cleanly" do
      for language_pair <- Vocabulary.language_pairs() do
        path = Path.join(["priv", "data", "#{language_pair}.tsv"])
        assert File.exists?(path), "missing seed data for #{language_pair}"

        rows = path |> File.read!() |> ImportWords.parse(language_pair, "seed")
        assert rows != []

        for row <- rows do
          assert {:ok, _word} = Vocabulary.upsert_word(row)
        end
      end
    end
  end
end
