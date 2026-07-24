defmodule Linguaswap.Vocabulary.Word do
  use Ecto.Schema
  import Ecto.Changeset

  schema "words" do
    field :original_word, :string
    field :target_translation, :string
    field :language_pair, :string
    field :frequency_rank, :integer
    field :difficulty_score, :integer

    has_many :user_words, Linguaswap.Vocabulary.UserWord

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(word, attrs) do
    word
    |> cast(attrs, [
      :original_word,
      :target_translation,
      :language_pair,
      :frequency_rank,
      :difficulty_score
    ])
    |> validate_required([:original_word, :target_translation, :language_pair])
    |> unique_constraint([:original_word, :language_pair])
  end
end
