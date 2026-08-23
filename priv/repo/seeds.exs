# Seeds the dictionary from the per-language-pair data files in priv/data.
#
# The word lists live in TSV rather than in this script so that swapping in a
# real frequency dataset is a file drop, not a code change. Re-running is safe:
# the importer upserts on (original_word, language_pair).

alias Linguaswap.Vocabulary.Word

for language_pair <- Word.language_pairs() do
  path = Application.app_dir(:linguaswap, "priv/data/#{language_pair}.tsv")

  if File.exists?(path) do
    Mix.Tasks.Linguaswap.ImportWords.run([
      path,
      "--language-pair",
      language_pair,
      "--source",
      "seed"
    ])
  else
    IO.puts("No seed data for #{language_pair} at #{path}, skipping.")
  end
end
