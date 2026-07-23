defmodule Linguaswap.Repo.Migrations.CreateUserWords do
  use Ecto.Migration

  def change do
    create table(:user_words, primary_key: false) do
      add :id, :bigint, primary_key: true, autogenerate: true
      add :user_id, references(:email, on_delete: :delete_all), null: false
      add :word_id, references(:words, on_delete: :delete_all), null: false
      add :reveal_count, :integer, default: 0, null: false
      add :replacement_count, :integer, default: 0, null: false
      add :last_revealed_at, :utc_datetime
      add :status, :string, default: "new", null: false

      timestamps(type: :utc_datetime)
    end

    create index(:user_words, [:user_id])
    create index(:user_words, [:word_id])
    create unique_index(:user_words, [:user_id, :word_id])
  end
end
