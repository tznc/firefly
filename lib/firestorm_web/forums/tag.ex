defmodule FirestormWeb.Forums.Tag do
  @moduledoc """
  A tag on threads. Names are lowercase and URL-safe (letters, digits and
  inner dashes, up to 30 characters), so they work as-is in `/tags/:name`.
  A thread has at most `max_per_thread/0` tags.

  A tag may be in a group (see `FirestormWeb.Forums.TagGroup`) and may be a
  synonym of another, canonical tag: applying the synonym applies the
  canonical tag, and its page redirects there (see `FirestormWeb.Tags`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FirestormWeb.Forums.{TagGroup, Thread}

  @max_length 30
  @name_format ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  schema "forums_tags" do
    field(:name, :string)
    field(:threads_count, :integer, virtual: true)
    belongs_to(:group, TagGroup)
    belongs_to(:synonym_of, __MODULE__)
    has_many(:synonyms, __MODULE__, foreign_key: :synonym_of_id, preload_order: [asc: :name])
    many_to_many(:threads, Thread, join_through: "forums_threads_tags")

    timestamps(type: :naive_datetime_usec)
  end

  @doc "How many tags a thread may have (the `max_tags_per_thread` site setting)."
  def max_per_thread, do: FirestormWeb.SiteSettings.get("max_tags_per_thread")

  def changeset(%__MODULE__{} = tag, attrs) do
    tag
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_format(:name, @name_format)
    |> validate_length(:name, max: @max_length)
    |> unique_constraint(:name)
  end

  @doc """
  Tag names from user input (comma- or space-separated), downcased, without
  repeats. A `#` before a name is dropped.
  """
  @spec parse(String.t() | nil) :: [String.t()]
  def parse(nil), do: []

  def parse(input) when is_binary(input) do
    input
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&(&1 |> String.trim_leading("#") |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc "The tag a synonym stands for (its `synonym_of` loaded), or the tag itself."
  def canonical(%__MODULE__{synonym_of: %__MODULE__{} = canonical}), do: canonical
  def canonical(%__MODULE__{} = tag), do: tag

  @doc "Whether only staff may apply the tag (its `group` loaded)."
  def staff_only?(%__MODULE__{group: %TagGroup{staff_only: true}}), do: true
  def staff_only?(%__MODULE__{}), do: false

  @doc "Tags input with `name` added (once), as the picker fills the field."
  def append(input, name),
    do: input |> parse() |> Kernel.++([name]) |> Enum.uniq() |> Enum.join(", ")

  @doc "Whether `name` (already parsed) is a valid tag name."
  def valid_name?(name),
    do: String.length(name) <= @max_length and Regex.match?(@name_format, name)
end
