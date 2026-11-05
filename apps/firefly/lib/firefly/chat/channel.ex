defmodule Firefly.Chat.Channel do
  @moduledoc """
  A chat channel (see `Firefly.Chat`). `kind` is `"category"` (a named
  channel staff create, for everyone who may use chat or, with a
  `category_id`, for those who may read that category) or `"direct"` (a
  direct message between two or more people, its members; `direct_key`
  is their sorted ids, so the same people always share one channel).

  `status`: `"open"`, `"closed"` (only staff post), `"read_only"` (nobody
  posts) or `"archived"` (read-only, and out of the channel list for
  those who don't follow it).
  """

  use Ecto.Schema
  use Firefly.Changeset

  alias Firefly.Accounts.User
  alias Firefly.Discussion.Category

  @statuses ~w(open closed read_only archived)

  schema "chat_channels" do
    field(:kind, :string, default: "category")
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:status, :string, default: "open")
    field(:direct_key, :string)
    field(:allow_channel_wide_mentions, :boolean, default: true)
    field(:last_message_at, :naive_datetime_usec)
    belongs_to(:category, Category)
    belongs_to(:created_by, User)

    # The members of a direct message channel, when loaded for display.
    field(:members, {:array, :any}, virtual: true, default: [])

    timestamps(type: :naive_datetime_usec)
  end

  @doc "Every status, in display order."
  def statuses, do: @statuses

  def direct?(%__MODULE__{kind: kind}), do: kind == "direct"

  @doc "The changeset for staff creating or editing a category channel."
  def changeset(%__MODULE__{} = channel, attrs) do
    channel
    |> cast(attrs, [:name, :slug, :description, :category_id, :allow_channel_wide_mentions])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 50)
    |> validate_length(:description, max: 500)
    |> put_slug()
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "use lowercase letters, digits and dashes"
    )
    |> validate_length(:slug, max: 50)
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:category_id)
  end

  # A blank slug is made from the name.
  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      blank when blank in [nil, ""] ->
        put_change(changeset, :slug, slugify(get_field(changeset, :name)))

      _slug ->
        changeset
    end
  end

  @doc "A slug for `name`: lowercase ASCII words joined by dashes."
  def slugify(nil), do: nil

  def slugify(name) do
    name
    |> String.normalize(:nfd)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc "A changeset for a status change."
  def status_changeset(%__MODULE__{} = channel, status) do
    channel
    |> change(status: status)
    |> validate_inclusion(:status, @statuses)
  end
end
