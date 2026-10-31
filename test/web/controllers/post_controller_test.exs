defmodule FirestormWeb.Web.PostControllerTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  setup do
    {:ok, category} = Forums.create_category(%{title: "Category"})

    {:ok, user} =
      Forums.create_user(%{username: "knewter", email: "josh@dailydrip.com", name: "Josh Adams"})

    {:ok, thread} = Forums.create_thread(category, user, %{title: "Thread", body: "First"})

    {:ok, category: category, thread: thread, conn: log_in_as(build_conn(), user)}
  end

  test "creates a post and redirects to the thread", %{
    conn: conn,
    category: category,
    thread: thread
  } do
    conn =
      post(conn, category_thread_post_path(conn, :create, category, thread),
        post: %{body: "A reply"}
      )

    assert redirected_to(conn) == category_thread_path(conn, :show, category, thread)
  end

  test "re-renders the form when the post is invalid", %{
    conn: conn,
    category: category,
    thread: thread
  } do
    conn =
      post(conn, category_thread_post_path(conn, :create, category, thread), post: %{body: ""})

    assert html_response(conn, 200) =~ "can&#39;t be blank"
  end
end
