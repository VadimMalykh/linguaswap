defmodule Linguaswap.Vocabulary.Word do
  use Ecto.Schema
  import Ecto.Changeset

  @language_pairs ~w(en-es en-uz)

  @doc """
  Language pairs the app knows how to serve.

  `language_pair` used to be a free-form string; validating it here keeps typos
  out of the dictionary and gives the extension a single source of truth.
  """
  def language_pairs, do: @language_pairs

  schema "words" do
    field :original_word, :string
    field :target_translation, :string
    field :language_pair, :string
    field :frequency_rank, :integer
    field :difficulty_score, :integer

    # Canonical English base form. Lookups are keyed on this once the client
    # lemmatizes page text (Phase 2).
    field :lemma, :string
    field :pos, :string

    # 1 for a single word, >1 for a phrase entry (Phase 3).
    field :token_count, :integer, default: 1

    # Target-side inflected forms, filled by the LLM pipeline (Phase 4),
    # e.g. %{"past" => "corrió", "gerund" => "corriendo"}.
    field :forms, :map, default: %{}

    field :source, :string, default: "seed"

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
      :difficulty_score,
      :lemma,
      :pos,
      :token_count,
      :forms,
      :source
    ])
    |> validate_required([:original_word, :target_translation, :language_pair])
    |> validate_inclusion(:language_pair, @language_pairs)
    |> validate_number(:frequency_rank, greater_than: 0)
    |> validate_number(:token_count, greater_than: 0)
    |> put_derived_lemma()
    |> put_derived_token_count()
    |> unique_constraint([:original_word, :language_pair])
  end

  # A dictionary entry is a base form unless the caller says otherwise, so the
  # lemma defaults to the entry itself rather than being left null.
  defp put_derived_lemma(changeset) do
    case {get_field(changeset, :lemma), get_field(changeset, :original_word)} do
      {nil, original} when is_binary(original) ->
        put_change(changeset, :lemma, String.downcase(original))

      _ ->
        changeset
    end
  end

  defp put_derived_token_count(changeset) do
    case {get_change(changeset, :token_count), get_field(changeset, :original_word)} do
      {nil, original} when is_binary(original) ->
        put_change(changeset, :token_count, length(String.split(original, ~r/\s+/, trim: true)))

      _ ->
        changeset
    end
  end
end
