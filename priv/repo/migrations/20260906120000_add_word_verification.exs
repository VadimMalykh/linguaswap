defmodule Linguaswap.Repo.Migrations.AddWordVerification do
  use Ecto.Migration

  def change do
    alter table(:words) do
      # Evidence for the generated data in this row: per-field verdicts, the
      # verifier that spoke and the tier it sits at. Phase 4.5 approves from
      # this rather than from a human reading every row, so the reason an entry
      # is being served has to survive in the row itself.
      add :verification, :map, default: fragment("'{}'::jsonb"), null: false
      add :verified_at, :utc_datetime

      # Romanised pronunciation for targets whose script gives a learner no way
      # to sound the word out — pinyin for Chinese. Null everywhere else, and
      # for a Latin-script target it stays null rather than repeating the word.
      add :pronunciation, :string
    end

    # The verification pass walks entries that have never been checked, the
    # same way generation walks entries that have never been generated.
    create index(:words, [:language_pair, :verified_at])
  end
end
