defmodule Linguaswap.Repo.Migrations.AddTargetLanguageToUsers do
  use Ecto.Migration

  def change do
    alter table("email") do
      add :target_language, :string, default: "es"
      add :settings, :map, default: %{}
    end
  end
end
