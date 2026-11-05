defmodule Firefly.Moderation.WatchedWord do
  @moduledoc """
  A word staff watch for (see `Firefly.Moderation.WatchedWords`): `word`
  with `*` wildcards, or a regular expression when `regex` is set, and the
  `action` taken when someone writes it. `replace` takes the replacement
  text, `link` a URL and `tag` the tag names (comma-separated) in
  `replacement`.
  """
  use Ecto.Schema
  use Firefly.Changeset

  alias Firefly.Accounts.User

  @actions ~w(block censor require_approval flag replace tag silence link)
  @with_replacement ~w(replace tag link)

  schema "watched_words" do
    field(:word, :string)
    field(:action, :string)
    field(:regex, :boolean, default: false)
    field(:replacement, :string)
    belongs_to(:created_by, User)

    timestamps(type: :naive_datetime_usec)
  end

  @doc "Every action, in display order."
  def actions, do: @actions

  @doc "Whether `action` takes a replacement (text, URL or tags)."
  def replacement?(action), do: action in @with_replacement

  def changeset(%__MODULE__{} = word, attrs) do
    word
    |> cast(attrs, [:word, :action, :regex, :replacement])
    |> update_change(:word, &String.trim/1)
    |> update_change(:replacement, &String.trim/1)
    |> validate_required([:word, :action])
    |> validate_inclusion(:action, @actions)
    |> validate_length(:word, max: 100)
    |> validate_length(:replacement, max: 255)
    |> validate_pattern()
    |> validate_replacement()
    |> unique_constraint(:word,
      name: :watched_words_action_word_index,
      message: "is already watched for this action"
    )
  end

  defp validate_pattern(changeset) do
    validate_change(changeset, :word, fn :word, word ->
      cond do
        not get_field(changeset, :regex) and String.trim(word, "*") == "" ->
          [word: "needs more than wildcards"]

        get_field(changeset, :regex) and match?({:error, _}, Regex.compile(word, "iu")) ->
          [word: "is not a valid regular expression"]

        get_field(changeset, :regex) and Regex.match?(Regex.compile!(word, "iu"), "") ->
          [word: "matches empty text"]

        true ->
          []
      end
    end)
  end

  defp validate_replacement(changeset) do
    action = get_field(changeset, :action)

    if replacement?(action) do
      changeset
      |> validate_required(:replacement, message: "can't be blank for this action")
      |> validate_change(:replacement, &replacement_errors(action, &1, &2))
    else
      put_change(changeset, :replacement, nil)
    end
  end

  defp replacement_errors("link", :replacement, url) do
    if url =~ ~r{\Ahttps?://[^\s]+\z} or url =~ ~r{\A/[^/\s][^\s]*\z},
      do: [],
      else: [replacement: "must be an http(s) URL or a path on this site"]
  end

  defp replacement_errors("tag", :replacement, tags) do
    if tags |> tag_names() |> Enum.all?(&(&1 =~ ~r/\A[a-z0-9-]{1,30}\z/)) and tags != "",
      do: [],
      else: [replacement: "must be tag names (lowercase letters, digits and dashes)"]
  end

  defp replacement_errors(_action, :replacement, _text), do: []

  @doc "A `tag` word's tag names."
  def tag_names(replacement),
    do: replacement |> String.downcase() |> String.split([",", " "], trim: true)
end
