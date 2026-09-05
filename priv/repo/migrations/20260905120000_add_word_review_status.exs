defmodule Linguaswap.Repo.Migrations.AddWordReviewStatus do
  use Ecto.Migration

  def change do
    alter table(:words) do
      # Where a generated entry sits in the review workflow (Phase 4):
      # `pending` until a human looks at it, then `approved` or `rejected`.
      # NULL means the entry was never generated — every seeded and imported
      # row — so hand-authored data needs no approval to be served.
      add :review_status, :string
    end

    # The review queue reads exactly this: one pair, pending first.
    create index(:words, [:language_pair, :review_status])
  end
end
