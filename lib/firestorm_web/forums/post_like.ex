defmodule FirestormWeb.Forums.PostLike do
  @moduledoc "A user's like on a post (at most one per user per post)."

  use Ecto.Schema

  alias FirestormWeb.Forums.{Post, User}

  schema "forums_post_likes" do
    belongs_to(:post, Post)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
