defmodule Linguaswap.Repo.Migrations.AddWordMetadata do
  use Ecto.Migration

  def change do
    alter table(:words) do
      add :lemma, :string
      add :pos, :string
      add :token_count, :integer, default: 1, null: false
      add :forms, :map, default: fragment("'{}'::jsonb"), null: false
      add :source, :string, default: "seed", null: false
    end

    # Existing entries are dictionary base forms, so the lemma is the word itself.
    execute "UPDATE words SET lemma = lower(original_word)",
            "UPDATE words SET lemma = NULL"

    execute "UPDATE words SET token_count = array_length(string_to_array(original_word, ' '), 1)",
            "UPDATE words SET token_count = 1"

    # Frontier ordering (Phase 1) and lemma lookup (Phase 2).
    create index(:words, [:language_pair, :frequency_rank])
    create index(:words, [:language_pair, :lemma])

    alter table(:user_words) do
      add :activated_at, :utc_datetime
    end

    create index(:user_words, [:user_id, :status])
  end
end
