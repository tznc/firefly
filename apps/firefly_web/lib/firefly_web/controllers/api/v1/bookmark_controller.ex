defmodule FireflyWeb.Api.V1.BookmarkController do
  @moduledoc "`GET /bookmarks`: the user's bookmarks of posts they may still read."
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Discussion.Bookmarks
  alias FireflyWeb.Api.Pagination

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_user)
  plug(:require_scope, "read")

  def index(conn, params) do
    Pagination.render(conn, Bookmarks.list(current_user(conn)), params, fn bookmark ->
      %{
        id: bookmark.id,
        post_id: bookmark.post_id,
        thread_id: bookmark.post.thread_id,
        thread_title: bookmark.post.thread.title,
        note: bookmark.note,
        remind_at: bookmark.remind_at,
        inserted_at: bookmark.inserted_at
      }
    end)
  end
end
