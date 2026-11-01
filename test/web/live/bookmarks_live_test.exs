defmodule FirestormWeb.Web.BookmarksLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.{Bookmarks, Forums, Repo}
  alias FirestormWeb.Forums.Bookmark

  setup do
    author = user_fixture(%{username: "author"})
    reader = user_fixture(%{username: "reader"})
    category = category_fixture()
    thread = thread_fixture(category, author, %{title: "Worth keeping", body: "first post"})
    {:ok, reply} = Forums.create_post(thread, author, %{body: "the good part"})
    %{author: author, reader: reader, thread: thread, reply: reply}
  end

  defp path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  test "bookmark a post with a note and reminder, then remove it", %{
    conn: conn,
    reader: reader,
    thread: thread,
    reply: reply
  } do
    session =
      conn
      |> log_in_as(reader)
      |> visit(path(thread))
      |> click_button("Bookmark post #{reply.id}")
      |> assert_has("#bookmark-form")
      |> fill_in("Note (optional)", with: "reread this")
      |> select("Remind me", option: "Tomorrow")
      |> click_button("Save")
      |> assert_has("#flash-info", text: "Bookmark saved")
      |> refute_has("#bookmark-form")

    assert %Bookmark{note: "reread this", remind_at: %DateTime{}} =
             Repo.get_by!(Bookmark, post_id: reply.id)

    session
    |> click_button("Remove bookmark of post #{reply.id}")
    |> assert_has("button[aria-label='Bookmark post #{reply.id}']")

    assert Repo.all(Bookmark) == []
  end

  test "no bookmark toggle for visitors", %{conn: conn, thread: thread, reply: reply} do
    conn
    |> visit(path(thread))
    |> assert_has("#post-#{reply.id}")
    |> refute_has(".bookmark-toggle")
  end

  test "the bookmarks page edits, clears reminders and deletes", %{
    conn: conn,
    reader: reader,
    reply: reply
  } do
    {:ok, bookmark} = Bookmarks.bookmark(reader, reply)

    {:ok, _} =
      Bookmarks.update(reader, bookmark.id, %{"note" => "old note", "reminder" => "next_week"})

    conn
    |> log_in_as(reader)
    |> visit(~p"/bookmarks")
    |> assert_has("#bookmark-#{bookmark.id}", text: "Worth keeping")
    |> assert_has("#bookmark-#{bookmark.id} .bookmark-note", text: "old note")
    |> assert_has("#bookmark-#{bookmark.id} .bookmark-reminder")
    |> click_button("Clear reminder")
    |> assert_has("#flash-info", text: "Reminder cleared")
    |> refute_has(".bookmark-reminder")
    |> click_button("Edit")
    |> fill_in("Note (optional)", with: "new note")
    |> select("Remind me", option: "At a time…")
    |> click_button("Save")
    |> assert_has("#bookmark-form", text: "needs a date and time")
    |> fill_in("Time (for “At a time…”)", with: "2099-01-02T09:30")
    |> click_button("Save")
    |> assert_has("#flash-info", text: "Bookmark saved")
    |> assert_has(".bookmark-note", text: "new note")
    |> assert_has(".bookmark-reminder")
    |> click_button("Delete")
    |> assert_has("#no-bookmarks")

    assert Repo.all(Bookmark) == []
  end

  test "a fired reminder shows in notifications and updates the page", %{
    conn: conn,
    reader: reader,
    reply: reply
  } do
    {:ok, bookmark} = Bookmarks.bookmark(reader, reply)
    {:ok, _} = Bookmarks.update(reader, bookmark.id, %{"reminder" => "later_today"})

    session =
      conn
      |> log_in_as(reader)
      |> visit(~p"/bookmarks")
      |> assert_has(".bookmark-reminder")

    assert Bookmarks.run_due(DateTime.add(DateTime.utc_now(), 4, :hour)) == 1

    session
    |> refute_has(".bookmark-reminder")
    |> visit(~p"/notifications")
    |> assert_has("li", text: "Reminder: your bookmark in")
  end

  test "a bookmark of a post deleted since is hidden", %{
    conn: conn,
    author: author,
    reader: reader,
    reply: reply
  } do
    {:ok, _} = Bookmarks.bookmark(reader, reply)
    {:ok, _} = Forums.delete_post(reply, author)

    conn
    |> log_in_as(reader)
    |> visit(~p"/bookmarks")
    |> assert_has("#no-bookmarks")
  end
end
