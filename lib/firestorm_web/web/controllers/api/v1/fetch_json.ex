defmodule FirestormWeb.Web.Api.V1.FetchJSON do
  @moduledoc """
  JSON for a `FirestormWeb.Store.ReplenishResponse`, as pushed to channel
  clients.
  """
  alias FirestormWeb.Store.ReplenishResponse
  alias FirestormWeb.Web.Api.V1.{CategoryJSON, PostJSON, ThreadJSON, UserJSON}

  def index(%ReplenishResponse{} = response) do
    %{
      categories: Enum.map(response.categories, &CategoryJSON.data/1),
      threads: Enum.map(response.threads, &ThreadJSON.data/1),
      posts: Enum.map(response.posts, &PostJSON.data/1),
      users: Enum.map(response.users, &UserJSON.data/1)
    }
  end
end
