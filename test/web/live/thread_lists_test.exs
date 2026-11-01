defmodule FirestormWeb.Web.ThreadListsTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  setup do
    author = user_fixture()
    reader = user_fixture()
    category = category_fixture()
    thread = thread_fixture(category, author, %{title: "Read me"})
    %{author: author, reader: reader, category: category, thread: thread}
  end

  test "Latest shows tabs; New and Unread only for members", %{conn: conn, reader: reader} do
    conn
    |> visit(~p"/")
    |> assert_has("#list-tabs a", text: "Latest")
    |> assert_has("#list-tabs a", text: "Top")
    |> refute_has("#list-tabs a", text: "Unread")

    conn
    |> log_in_as(reader)
    |> visit(~p"/")
    |> assert_has("#list-tabs a", text: "New")
    |> assert_has("#list-tabs a", text: "Unread")
  end

  test "New and Unread require logging in", %{conn: conn} do
    for path <- ["/new", "/unread"] do
      conn |> visit(path) |> refute_has("#list-tabs")
    end
  end

  test "a thread is New until opened, then Unread once someone replies", %{
    conn: conn,
    author: author,
    reader: reader,
    thread: thread
  } do
    conn = log_in_as(conn, reader)

    conn
    |> visit(~p"/new")
    |> assert_has("#thread-#{thread.id} .new-badge", text: "new")

    # Opening the thread marks it read (and nothing is "new since last visit" yet)
    conn
    |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}")
    |> refute_has("#new-posts-divider")

    conn |> visit(~p"/new") |> refute_has("#thread-#{thread.id}")
    conn |> visit(~p"/unread") |> refute_has("#thread-#{thread.id}")
    assert Forums.thread_read(reader, thread)
  end

  test "Unread links to the first unread post, which the thread marks", %{
    conn: conn,
    author: author,
    reader: reader,
    category: category
  } do
    # Read earlier (not open in this test, so new posts stay unread)
    other = thread_fixture(category, author, %{title: "Read earlier"})
    {:ok, _} = Forums.mark_thread_read(reader, other)
    {:ok, reply} = Forums.create_post(other, author, %{body: "Something new"})

    conn = log_in_as(conn, reader)

    conn
    |> visit(~p"/unread")
    |> assert_has("#thread-#{other.id} .unread-badge", text: "1 unread")
    |> assert_has(~s(#thread-#{other.id} a.unread-badge[href$="#post-#{reply.id}"]))

    conn
    |> visit(~p"/categories/#{other.category_id}/threads/#{other}")
    |> assert_has("#new-posts-divider", text: "New since your last visit")

    conn |> visit(~p"/unread") |> refute_has("#thread-#{other.id}")
  end

  test "Top lists the most active threads for a period", %{conn: conn, thread: thread} do
    conn
    |> visit(~p"/top")
    |> assert_has("#top-periods a.btn-active", text: "Week")
    |> assert_has("#thread-#{thread.id}")
    |> click_link("#top-periods a", "Day")
    |> assert_has("#top-periods a.btn-active", text: "Day")
    |> assert_has("#thread-#{thread.id}")
  end

  test "Top doesn't re-rank live on every post", %{conn: conn, author: author, category: category} do
    require Phoenix.LiveViewTest
    {:ok, view, _html} = Phoenix.LiveViewTest.live(conn, ~p"/top")
    thread_fixture(category, author, %{title: "Brand new"})
    refute Phoenix.LiveViewTest.render(view) =~ "Brand new"
  end
end
