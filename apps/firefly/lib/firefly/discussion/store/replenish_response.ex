defmodule Firefly.Discussion.Store.ReplenishResponse do
  @moduledoc """
  The categories, threads, users and posts sent to clients in response to a replenish request.
  """

  defstruct categories: [], threads: [], users: [], posts: []
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Category, Post, Thread}

  @type t :: %Firefly.Discussion.Store.ReplenishResponse{
          categories: list(%Category{}),
          threads: list(%Thread{}),
          users: list(%User{}),
          posts: list(%Post{})
        }
end
