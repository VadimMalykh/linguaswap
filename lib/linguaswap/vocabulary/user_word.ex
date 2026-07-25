defmodule Linguaswap.Vocabulary.UserWord do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "user_words" do
    field :reveal_count, :integer, default: 0
    field :replacement_count, :integer, default: 0
    field :exposure_count, :integer, default: 0
    field :last_revealed_at, :utc_datetime
    field :status, :string, default: "hard"

    belongs_to :user, Linguaswap.Accounts.User
    belongs_to :word, Linguaswap.Vocabulary.Word

    timestamps(type: :utc_datetime)
  end

  def changeset(user_word, attrs) do
    user_word
    |> cast(attrs, [
      :reveal_count,
      :replacement_count,
      :exposure_count,
      :last_revealed_at,
      :status
    ])
    |> validate_required([:user_id, :word_id])
  end
end
