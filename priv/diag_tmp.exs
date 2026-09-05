import Ecto.Query
alias Linguaswap.{Repo, Vocabulary.Word}

Repo.all(from w in Word, where: w.language_pair == "en-es" and w.review_status == "pending",
         order_by: w.frequency_rank)
|> Enum.each(fn w ->
  forms = w.forms |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.sort() |> Enum.join("  ")
  IO.puts("#{String.pad_trailing(w.original_word, 8)} #{String.pad_trailing(w.pos, 11)} #{String.pad_trailing(w.target_translation, 10)} #{forms}")
end)
IO.puts("\nspend recorded: #{inspect(Linguaswap.LLM.Budget.stats())}")
