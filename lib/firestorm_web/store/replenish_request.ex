defmodule FirestormWeb.Store.ReplenishRequest do
  @moduledoc """
  A request from a client for categories, threads, users and posts by id.
  """

  defstruct categories: [], threads: [], users: [], posts: []

  @typep finder :: integer | String.t()

  @type t :: %FirestormWeb.Store.ReplenishRequest{
          categories: list(finder),
          threads: list(finder),
          users: list(finder),
          posts: list(finder)
        }

  def request_category(%__MODULE__{} = request, category_id) do
    %{request | categories: [category_id | request.categories]}
  end

  def request_thread(%__MODULE__{} = request, thread_id) do
    %{request | threads: [thread_id | request.threads]}
  end

  def request_user(%__MODULE__{} = request, user_id) do
    %{request | users: [user_id | request.users]}
  end

  def request_post(%__MODULE__{} = request, post_id) do
    %{request | posts: [post_id | request.posts]}
  end
end
