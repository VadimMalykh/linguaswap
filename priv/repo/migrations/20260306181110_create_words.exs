defmodule Linguaswap.Repo.Migrations.CreateWords do
  use Ecto.Migration

  def change do
    create table(:words) do
      add :original_word, :string
      add :target_translation, :string
      add :language_pair, :string
      add :frequency_rank, :integer
      add :difficulty_score, :integer
      add :user_id, references(:email, type: :id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:words, [:user_id])
  end
end
