defmodule Firefly.Discussion.ReadTrackingTest do
  use Firefly.DataCase, async: true

  alias Firefly.{Accounts, Discussion, Repo}
  alias Firefly.Discussion.{Post, Thread}

  defp user(name) do
    {:ok, user} =
      Accounts.create_user(%{username: name, name: name, email: "#{name}@example.com"})

    user
  end

  setup do
    {:ok, category} = Discussion.create_category(%{title: "Elixir"})
    author = user("author")
    reader = user("reader")
    {:ok, thread} = Discussion.create_thread(category, author, %{title: "T", body: "first"})
    %{category: category, author: author, reader: reader, thread: thread}
  end

  defp reply(thread, user, body) do
    {:ok, post} = Discussion.create_post(thread, user, %{body: body})
    post
  end

  defp find(threads, %Thread{id: id}), do: Enum.find(threads, &(&1.id == id))

  test "a never-opened thread is new and fully unread", %{
    author: author,
    reader: reader,
    thread: thread
  } do
    reply(thread, author, "second")
    listed = find(Discussion.latest_threads(reader), thread)

    assert listed.new?
    assert listed.posts_count == 2
    assert listed.unread_count == 2
    refute listed.completely_read?
    assert find(Discussion.new_threads(reader), thread)
  end

  test "reading moves the position; later posts count as unread", %{
    author: author,
    reader: reader,
    thread: thread
  } do
    {:ok, _} = Discussion.mark_thread_read(reader, thread)
    listed = find(Discussion.latest_threads(reader), thread)
    assert listed.completely_read?
    refute listed.new?
    assert listed.unread_count == 0
    refute find(Discussion.new_threads(reader), thread)
    assert Discussion.unread_threads(reader) == []

    post = reply(thread, author, "news")
    reply(thread, author, "more news")

    listed = find(Discussion.unread_threads(reader), thread)
    assert listed.unread_count == 2
    assert listed.first_unread_post_id == post.id
    refute listed.completely_read?
  end

  test "the read position never moves backwards", %{reader: reader, thread: thread} do
    {:ok, _} = Discussion.mark_thread_read(reader, thread)
    last = Repo.one(from(p in Post, where: p.thread_id == ^thread.id, select: max(p.id)))

    # Simulate a stale write with an older position
    Repo.update_all(
      from(r in Firefly.Discussion.ThreadRead, where: r.thread_id == ^thread.id),
      set: [last_read_post_id: last + 100]
    )

    {:ok, _} = Discussion.mark_thread_read(reader, thread)
    assert Discussion.thread_read(reader, thread).last_read_post_id == last + 100
  end

  test "anonymous lists have no read state", %{thread: thread} do
    listed = find(Discussion.latest_threads(nil), thread)
    refute listed.new?
    assert listed.unread_count == 0
    # Nothing is "read" for anonymous visitors
    refute listed.completely_read?
  end

  test "authors have read their own thread and posts, however they posted", %{
    author: author,
    reader: reader,
    thread: thread
  } do
    listed = find(Discussion.latest_threads(author), thread)
    refute listed.new?
    assert listed.completely_read?

    {:ok, _} = Discussion.mark_thread_read(reader, thread)
    reply(thread, author, "a reply sent by email or the API")
    reply(thread, reader, "my own reply")

    assert Discussion.unread_threads(reader) == []
    assert find(Discussion.unread_threads(author), thread).unread_count == 1
  end

  test "threads older than the New window aren't flagged new", %{reader: reader, thread: thread} do
    Repo.update_all(from(t in Thread, where: t.id == ^thread.id),
      set: [inserted_at: ~N[2020-01-01 00:00:00]]
    )

    listed = find(Discussion.latest_threads(reader), thread)
    refute listed.new?
    assert listed.unread_count == 1
  end

  test "category lists are ordered by latest activity", %{
    category: category,
    author: author,
    thread: older
  } do
    {:ok, newer} = Discussion.create_thread(category, author, %{title: "Newer", body: "1"})
    assert Enum.map(Discussion.recent_threads(category), & &1.id) == [newer.id, older.id]

    reply(older, author, "bump")
    assert Enum.map(Discussion.recent_threads(category), & &1.id) == [older.id, newer.id]
  end

  test "top ranks threads by posts in the period", %{
    category: category,
    author: author,
    thread: quiet
  } do
    {:ok, busy} = Discussion.create_thread(category, author, %{title: "Busy", body: "1"})
    for n <- 2..4, do: reply(busy, author, "#{n}")

    # Old activity on the quiet thread doesn't count for the week
    for n <- 1..10, do: reply(quiet, author, "old #{n}")

    Repo.update_all(from(p in Post, where: p.thread_id == ^quiet.id),
      set: [inserted_at: ~N[2020-01-01 00:00:00.000000]]
    )

    assert [%{id: busy_id}] = Discussion.top_threads("week", nil)
    assert busy_id == busy.id
    assert [first, second] = Discussion.top_threads("all", nil)
    assert {first.id, second.id} == {quiet.id, busy.id}
  end
end
