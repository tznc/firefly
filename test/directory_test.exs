defmodule FirestormWeb.DirectoryTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.{Directory, Forums, Repo, Visits}
  alias FirestormWeb.Forums.{DirectoryItem, User}

  setup do
    alice = user_fixture(%{username: "alice", name: "Alice Liddell"})
    bob = user_fixture(%{username: "bob"})
    category = category_fixture()
    thread = thread_fixture(category, alice)
    {:ok, reply} = Forums.create_post(thread, bob, %{body: "Indeed"})
    {:ok, _} = Forums.create_post(thread, bob, %{body: "Twice"})
    Forums.like_post(reply, alice)

    %{alice: alice, bob: bob, thread: thread}
  end

  defp stats(user, period) do
    Repo.get_by!(DirectoryItem, user_id: user.id, period: period)
  end

  test "refresh computes each period's stats", %{alice: alice, bob: bob, thread: thread} do
    :ok = Visits.seen(Repo.get!(User, bob.id))
    {:ok, _} = Forums.mark_thread_read(alice, thread)
    :ok = Directory.refresh()

    assert %{topic_count: 1, post_count: 0, likes_given: 1, likes_received: 0} =
             stats(alice, "all")

    assert %{topic_count: 0, post_count: 2, likes_received: 1, days_visited: 1} =
             stats(bob, "day")

    # Alice read her first post as she wrote it, then Bob's two replies.
    assert %{posts_read: 3, topics_entered: 1} = stats(alice, "week")

    # Old activity drops out of the shorter periods.
    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -40, :day)
    Repo.update_all(Forums.Post, set: [inserted_at: old])
    Repo.update_all(Forums.PostLike, set: [inserted_at: old])
    :ok = Directory.refresh()
    assert %{post_count: 0, likes_received: 0} = stats(bob, "month")
    assert %{post_count: 2, likes_received: 1} = stats(bob, "year")
  end

  test "run_due refreshes only when stale" do
    :ok = Directory.run_due()
    first = Directory.refreshed_at()
    assert first
    :ok = Directory.run_due()
    assert Directory.refreshed_at() == first
  end

  test "seen records one visit a day and last_seen_at", %{alice: alice} do
    :ok = Visits.seen(alice)
    alice = Repo.get!(User, alice.id)
    assert alice.last_seen_at
    :ok = Visits.seen(alice)
    assert Repo.aggregate("user_visits", :count, :id) == 1
  end

  test "the directory page sorts, filters by period and searches", %{
    conn: conn,
    alice: alice,
    bob: bob
  } do
    hidden = user_fixture(%{username: "hidden"})
    {:ok, _} = Forums.update_preferences(hidden, %{hide_from_directory: true})
    :ok = Directory.refresh()

    conn
    |> visit(~p"/users")
    |> assert_has("#user-#{bob.id} .stat-likes_received", text: "1")
    |> assert_has("#user-#{alice.id} .stat-topic_count", text: "1")
    |> refute_has("#user-#{hidden.id}")
    |> assert_has("#users tbody tr:first-child", text: "bob")
    |> click_link("#sort-topic_count", "Topics")
    |> assert_has("#users tbody tr:first-child", text: "alice")
    |> click_link("#sort-topic_count", "Topics")
    |> assert_path(~p"/users", query_params: %{order: "topic_count", asc: "true"})
    |> click_link("Week")
    |> assert_path(~p"/users", query_params: %{period: "week", order: "topic_count", asc: "true"})
    |> fill_in("Search users", with: "liddell")
    |> assert_has("#users tbody tr", count: 1)
    |> assert_has("#user-#{alice.id}")
  end
end
