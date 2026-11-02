defmodule FirestormWeb.Forums.DirectoryItem do
  @moduledoc """
  A user's stats over a period (`"all"`, `"year"`, `"month"`, `"week"` or
  `"day"`), as of the last refresh (see `FirestormWeb.Directory`).
  """

  use Ecto.Schema

  alias FirestormWeb.Forums.User

  schema "directory_items" do
    field(:period, :string)
    field(:likes_received, :integer, default: 0)
    field(:likes_given, :integer, default: 0)
    field(:topic_count, :integer, default: 0)
    field(:post_count, :integer, default: 0)
    field(:days_visited, :integer, default: 0)
    field(:posts_read, :integer, default: 0)
    field(:topics_entered, :integer, default: 0)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec)
  end
end
