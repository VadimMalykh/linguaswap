defmodule Linguaswap.Vocabulary.PageVisit do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "page_visits" do
    field :url, :string
    field :words_replaced, :integer, default: 0
    field :time_spent_seconds, :integer, default: 0

    belongs_to :user, Linguaswap.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(page_visit, attrs) do
    page_visit
    |> cast(attrs, [:url, :words_replaced, :time_spent_seconds])
    |> validate_required([:user_id, :url])
  end
end
