defmodule FirestormWeb.Web.PostDeletionTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  setup do
    author = user_fixture(%{username: "author"})
    replier = user_fixture(%{username: "replier"})
    thread = thread_fixture(category_fixture(), author, %{title: "Deletions"})
    {:ok, reply} = Forums.create_post(thread, replier, %{body: "Oops, wrong thread"})
    %{author: author, replier: replier, thread: thread, reply: reply}
  end

  defp thread_path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  test "the author deletes a reply; members see a placeholder", ctx do
    %{conn: conn, replier: replier, thread: thread, reply: reply} = ctx
    reader = visit(conn, thread_path(thread))

    conn
    |> log_in_as(replier)
    |> visit(thread_path(thread))
    |> click_button("button[aria-label='Delete post #{reply.id}']", "")
    |> assert_has("#flash-info", text: "Post deleted.")
    |> assert_has("#post-#{reply.id}", text: "This post was deleted.")
    |> refute_has("#post-#{reply.id}", text: "Oops")
    |> assert_has("#reply-count", text: "0 replies")

    # Live for readers too
    reader
    |> assert_has("#post-#{reply.id}", text: "This post was deleted.")
    |> refute_has("#posts", text: "Oops, wrong thread")
  end

  test "the first post and other members' posts have no delete action", ctx do
    %{conn: conn, author: author, thread: thread, reply: reply} = ctx
    [first] = FirestormWeb.Repo.preload(thread, :posts).posts |> Enum.filter(&(&1.id != reply.id))

    conn
    |> log_in_as(author)
    |> visit(thread_path(thread))
    |> refute_has("button[aria-label='Delete post #{first.id}']")
    |> refute_has("button[aria-label='Delete post #{reply.id}']")
  end

  test "admins see deleted posts dimmed and restore them", ctx do
    %{conn: conn, replier: replier, thread: thread, reply: reply} = ctx
    {:ok, _} = Forums.delete_post(reply, replier)

    conn
    |> log_in_as(admin_fixture())
    |> visit(thread_path(thread))
    |> assert_has("#post-#{reply.id}.opacity-60", text: "Oops, wrong thread")
    |> assert_has("#post-#{reply.id} .badge", text: "deleted")
    |> click_button("#post-#{reply.id} button", "Restore")
    |> assert_has("#flash-info", text: "Post restored.")
    |> refute_has("#post-#{reply.id}.opacity-60")
    |> assert_has("#reply-count", text: "1 reply")
  end

  test "a deleted post's history is for admins only", ctx do
    %{conn: conn, replier: replier, thread: thread, reply: reply} = ctx
    {:ok, reply} = Forums.update_post(reply, replier, %{body: "Edited"})
    {:ok, _} = Forums.delete_post(reply, replier)
    history = thread_path(thread) <> "/posts/#{reply.id}/history"

    conn
    |> log_in_as(replier)
    |> visit(history)
    |> assert_path(thread_path(thread))
    |> assert_has("#flash-error", text: "This post was deleted.")

    build_conn()
    |> log_in_as(admin_fixture())
    |> visit(history)
    |> assert_has("#revision-1 del", text: "Oops,")
  end
end
