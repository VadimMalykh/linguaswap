defmodule Linguaswap.Repo.Migrations.AddWordsUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:words, [:original_word, :language_pair])
  end
end
