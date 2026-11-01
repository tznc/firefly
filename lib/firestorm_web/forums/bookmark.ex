defmodule FirestormWeb.Forums.Bookmark do
  @moduledoc """
  A post a user bookmarked (see `FirestormWeb.Bookmarks`), with an optional
  `note` and an optional reminder at `remind_at` (cleared once it fires).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FirestormWeb.Forums.{Post, User}

  schema "forums_bookmarks" do
    field(:note, :string)
    field(:remind_at, :utc_datetime)
    belongs_to(:user, User)
    belongs_to(:post, Post)

    timestamps(type: :naive_datetime_usec)
  end

  @doc "The note and reminder, as the user edits them."
  def changeset(%__MODULE__{} = bookmark, attrs) do
    bookmark
    |> cast(attrs, [:note, :remind_at])
    |> update_change(:note, &String.trim/1)
    |> validate_length(:note, max: 500)
    |> validate_change(:remind_at, fn :remind_at, at ->
      if DateTime.after?(at, DateTime.utc_now()),
        do: [],
        else: [remind_at: "must be in the future"]
    end)
  end
end
