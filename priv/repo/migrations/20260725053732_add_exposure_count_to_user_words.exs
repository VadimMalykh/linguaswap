defmodule Linguaswap.Repo.Migrations.AddExposureCountToUserWords do
  use Ecto.Migration

  def up do
    alter table(:user_words) do
      add :exposure_count, :integer, default: 0, null: false
    end

    execute "UPDATE user_words SET status = 'hard' WHERE status = 'new'"
    execute "UPDATE user_words SET status = 'simple' WHERE status = 'learning'"
    execute "UPDATE user_words SET status = 'trivial' WHERE status = 'known'"
  end

  def down do
    execute "UPDATE user_words SET status = 'new' WHERE status = 'hard'"
    execute "UPDATE user_words SET status = 'learning' WHERE status = 'simple'"
    execute "UPDATE user_words SET status = 'known' WHERE status = 'trivial'"

    alter table(:user_words) do
      remove :exposure_count
    end
  end
end
