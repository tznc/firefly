defmodule FirestormWeb.Forums.PostRevision do
  @moduledoc """
  A previous version of a post. Each edit stores the body it replaced, with
  the user who made the edit; `inserted_at` is when the edit happened.
  """

  use Ecto.Schema

  alias FirestormWeb.Forums.{Post, User}

  schema "forums_post_revisions" do
    field(:body, :string)
    belongs_to(:post, Post)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
