defmodule FirestormWeb.Store.ReplenishResponse do
  @moduledoc """
  The categories, threads, users and posts sent to clients in response to a replenish request.
  """

  defstruct categories: [], threads: [], users: [], posts: []
  alias FirestormWeb.Forums.{Category, Post, Thread, User}

  @type t :: %FirestormWeb.Store.ReplenishResponse{
          categories: list(%Category{}),
          threads: list(%Thread{}),
          users: list(%User{}),
          posts: list(%Post{})
        }
end
