defmodule Linguaswap.Vocabulary.Word do
  use Ecto.Schema
  import Ecto.Changeset

  @language_pairs ~w(en-es en-uz)

  @review_statuses ~w(pending approved rejected)

  # Parts of speech the generator may assign. A closed set because the client
  # reads it: whether an English "-s" means a plural or a third-person verb is
  # decided by the entry's POS, and a free-form label decides nothing.
  #
  # A phrase carries its head's part of speech — "give up" is a verb — so form
  # selection works the same for one word and for three.
  @parts_of_speech ~w(noun verb adjective adverb pronoun determiner preposition
                      conjunction interjection numeral other)

  # Target-side inflected forms, keyed by the English feature that asks for
  # them. The client detects the feature on the page word and looks the key up
  # here; anything missing falls back to `target_translation`.
  #
  # `plural` and `third_person` both come from an English "-s", separated by
  # POS. `past`/`past_participle`/`gerund` are verb forms,
  # `comparative`/`superlative` adjective and adverb ones.
  @form_keys ~w(plural third_person past past_participle gerund comparative superlative)

  @doc """
  Language pairs the app knows how to serve.

  `language_pair` used to be a free-form string; validating it here keeps typos
  out of the dictionary and gives the extension a single source of truth.
  """
  def language_pairs, do: @language_pairs

  @doc """
  Review states a generated entry moves through.
  """
  def review_statuses, do: @review_statuses

  @doc """
  Parts of speech an entry may carry.
  """
  def parts_of_speech, do: @parts_of_speech

  @doc """
  Keys the `forms` map may use.
  """
  def form_keys, do: @form_keys

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

    # `pending` / `approved` / `rejected` for generated entries, `nil` for
    # hand-authored ones. Only forms a human approved are served (Phase 4).
    field :review_status, :string

    has_many :user_words, Linguaswap.Vocabulary.UserWord

    timestamps(type: :utc_datetime)
  end

  @doc """
  The forms of an entry that may be sent to the client.

  Generated forms are withheld until a human approves them (Phase 4), so a
  model's guess never reaches a page on its own. Hand-authored entries carry no
  review status and are served as they stand.
  """
  def servable_forms(%__MODULE__{review_status: "pending"}), do: %{}
  def servable_forms(%__MODULE__{review_status: "rejected"}), do: %{}
  def servable_forms(%__MODULE__{forms: forms}) when is_map(forms), do: forms
  def servable_forms(_word), do: %{}

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
      :source,
      :review_status
    ])
    |> validate_required([:original_word, :target_translation, :language_pair])
    |> validate_inclusion(:language_pair, @language_pairs)
    |> validate_inclusion(:review_status, @review_statuses)
    |> validate_inclusion(:pos, @parts_of_speech)
    |> validate_number(:frequency_rank, greater_than: 0)
    |> validate_number(:token_count, greater_than: 0)
    |> put_derived_lemma()
    |> put_derived_token_count()
    |> validate_forms()
    |> unique_constraint([:original_word, :language_pair])
  end

  # Generated data arrives from a model, so the shape is checked rather than
  # trusted: an unknown key would be dead weight the client never asks for, and
  # a non-string value would reach the page as "[object Object]".
  defp validate_forms(changeset) do
    validate_change(changeset, :forms, fn :forms, forms ->
      cond do
        not is_map(forms) ->
          [forms: "must be a map"]

        Enum.any?(Map.keys(forms), &(&1 not in @form_keys)) ->
          [forms: "has unknown keys (allowed: #{Enum.join(@form_keys, ", ")})"]

        Enum.any?(Map.values(forms), &(not is_binary(&1))) ->
          [forms: "values must be strings"]

        true ->
          []
      end
    end)
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
