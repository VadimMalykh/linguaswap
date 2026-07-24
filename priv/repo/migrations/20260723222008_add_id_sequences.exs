defmodule Linguaswap.Repo.Migrations.AddIdSequences do
  use Ecto.Migration

  def up do
    execute "CREATE SEQUENCE IF NOT EXISTS user_words_id_seq OWNED BY user_words.id"
    execute "ALTER TABLE user_words ALTER COLUMN id SET DEFAULT nextval('user_words_id_seq')"

    execute "SELECT setval('user_words_id_seq', (SELECT COALESCE(MAX(id), 0) + 1 FROM user_words))"

    execute "CREATE SEQUENCE IF NOT EXISTS page_visits_id_seq OWNED BY page_visits.id"
    execute "ALTER TABLE page_visits ALTER COLUMN id SET DEFAULT nextval('page_visits_id_seq')"

    execute "SELECT setval('page_visits_id_seq', (SELECT COALESCE(MAX(id), 0) + 1 FROM page_visits))"
  end

  def down do
    execute "ALTER TABLE user_words ALTER COLUMN id DROP DEFAULT"
    execute "DROP SEQUENCE IF EXISTS user_words_id_seq"

    execute "ALTER TABLE page_visits ALTER COLUMN id DROP DEFAULT"
    execute "DROP SEQUENCE IF EXISTS page_visits_id_seq"
  end
end
