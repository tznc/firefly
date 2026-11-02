defmodule FireflyWeb.StoreChannel do
  @moduledoc """
  Fetches forum records for the legacy JSON client. The socket is anonymous,
  so it only serves what a visitor may read: records in restricted
  categories are left out.
  """
  use FireflyWeb, :channel
  alias Firefly.Discussion.Store.{ReplenishRequest, ReplenishResponse}
  alias FireflyWeb.Api.V1.FetchJSON
  alias Firefly.{Accounts, Discussion, Repo}

  def join("store:fetch", _payload, socket) do
    {:ok, socket}
  end

  def handle_in("fetch_home_data", _, socket) do
    # TODO: Make this not awful
    categories = Discussion.list_categories()

    # TODO: Set the current user
    threads =
      categories
      |> Enum.flat_map(&Discussion.recent_threads(&1, nil))

    posts =
      threads
      |> Enum.map(&Repo.preload(&1, posts: [:user]))
      |> Enum.flat_map(& &1.posts)
      |> Enum.map(&Discussion.decorate_post_oembeds/1)

    users =
      posts
      |> Enum.map(& &1.user)
      |> Enum.uniq_by(& &1.id)

    {:reply,
     {:ok,
      FetchJSON.index(%ReplenishResponse{
        categories: categories,
        threads: threads,
        posts: posts,
        users: users
      })}, socket}
  end

  def handle_in("fetch", replenish_request, socket) do
    replenish_request = %ReplenishRequest{
      categories: Map.get(replenish_request, "categories", []),
      threads: Map.get(replenish_request, "threads", []),
      posts: Map.get(replenish_request, "posts", []),
      users: Map.get(replenish_request, "users", [])
    }

    # TODO: Make this not awful
    categories =
      replenish_request.categories
      |> Enum.map(&Discussion.get_category!(&1))
      |> Enum.filter(&can?(nil, :view_category, &1))

    threads =
      replenish_request.threads
      |> Enum.map(&Discussion.get_thread!(&1))
      |> Enum.filter(&can?(nil, :view_thread, &1))

    posts =
      replenish_request.posts
      |> Enum.map(&Discussion.get_post!(&1))
      |> Enum.filter(&can?(nil, :view_thread, Discussion.get_thread!(&1.thread_id)))

    users =
      replenish_request.users
      |> Enum.map(&Accounts.get_user!(&1))

    {:reply,
     {:ok,
      FetchJSON.index(%ReplenishResponse{
        categories: categories,
        threads: threads,
        posts: posts,
        users: users
      })}, socket}
  end
end
