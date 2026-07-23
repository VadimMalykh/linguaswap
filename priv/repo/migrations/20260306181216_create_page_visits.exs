defmodule Linguaswap.Repo.Migrations.CreatePageVisits do
  use Ecto.Migration

  def change do
    create table(:page_visits, primary_key: false) do
      add :id, :bigint, primary_key: true, autogenerate: true
      add :user_id, references(:email, on_delete: :delete_all), null: false
      add :url, :string, null: false
      add :words_replaced, :integer, default: 0, null: false
      add :time_spent_seconds, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:page_visits, [:user_id])
    create index(:page_visits, [:inserted_at])
  end
end
