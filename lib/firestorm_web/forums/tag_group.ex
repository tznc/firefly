defmodule FirestormWeb.Forums.TagGroup do
  @moduledoc """
  A named group of tags (see `FirestormWeb.Tags`). A tag is in at most one
  group. `staff_only`: only admins may put its tags on threads.
  `one_per_thread`: a thread may have at most one of its tags.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FirestormWeb.Forums.Tag

  schema "forums_tag_groups" do
    field(:name, :string)
    field(:staff_only, :boolean, default: false)
    field(:one_per_thread, :boolean, default: false)
    has_many(:tags, Tag, foreign_key: :group_id, preload_order: [asc: :name])

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = group, attrs) do
    group
    |> cast(attrs, [:name, :staff_only, :one_per_thread])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 50)
    |> unique_constraint(:name)
  end
end
