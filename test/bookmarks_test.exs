defmodule FirestormWeb.BookmarksTest do
  use FirestormWeb.DataCase

  import FirestormWeb.Web.ConnCase,
    only: [user_fixture: 0, admin_fixture: 0, category_fixture: 1, thread_fixture: 3]

  alias FirestormWeb.{AccountDeletion, AccountExport, Bookmarks, Forums, Groups, TopicTimers}
  alias FirestormWeb.{TopicTools}
  alias FirestormWeb.Forums.{Bookmark, Notification, Post}

  setup do
    admin = admin_fixture()
    alice = user_fixture()
    bob = user_fixture()
    category = category_fixture("Elixir")
    thread = thread_fixture(category, alice, %{title: "Bookmarked", body: "op"})
    {:ok, reply} = Forums.create_post(thread, alice, %{body: "a reply worth keeping"})
    %{admin: admin, alice: alice, bob: bob, category: category, thread: thread, reply: reply}
  end

  defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(:second), seconds)

  defp remind(user, bookmark, at) do
    custom = FirestormWeb.LocalTime.to_input(at, 0)

    {:ok, bookmark} =
      Bookmarks.update(user, bookmark.id, %{"reminder" => "custom", "custom_at" => custom})

    bookmark
  end

  defp reminders(user),
    do:
      Repo.all(
        from(n in Notification, where: n.user_id == ^user.id and n.kind == "bookmark_reminder")
      )

  test "bookmark, note, list and remove; private to the user", %{
    alice: alice,
    bob: bob,
    reply: reply
  } do
    {:ok, bookmark} = Bookmarks.bookmark(bob, reply)
    # Twice is the same bookmark.
    assert {:ok, %Bookmark{id: id}} = Bookmarks.bookmark(bob, reply)
    assert id == bookmark.id

    {:ok, _} = Bookmarks.update(bob, bookmark.id, %{"note" => "  read later  ", "reminder" => ""})

    assert [%Bookmark{note: "read later", remind_at: nil, post: %Post{id: post_id}}] =
             Bookmarks.list(bob)

    assert post_id == reply.id
    assert Bookmarks.bookmarked_ids(bob, [reply]) == MapSet.new([reply.id])
    assert Bookmarks.bookmarked_ids(nil, [reply]) == MapSet.new()

    # Nobody else sees or changes it.
    assert Bookmarks.list(alice) == []
    assert Bookmarks.get(alice, bookmark.id) == nil
    assert {:error, :not_found} = Bookmarks.update(alice, bookmark.id, %{"note" => "mine"})
    :ok = Bookmarks.delete(alice, bookmark.id)
    :ok = Bookmarks.clear_reminder(alice, bookmark.id)
    assert [_] = Bookmarks.list(bob)

    :ok = Bookmarks.delete(bob, bookmark.id)
    assert Bookmarks.list(bob) == []
  end

  test "only posts the user can read", %{admin: admin, alice: alice, bob: bob, thread: thread} do
    {:ok, team} = Groups.create_group(%{name: "team"}, admin)
    {:ok, secret} = Forums.create_category(%{title: "Secret", role_ids: [team.id]})
    secret_thread = thread_fixture(secret, admin, %{title: "Secret", body: "classified"})
    secret_post = Repo.one(from(p in Post, where: p.thread_id == ^secret_thread.id))
    assert {:error, :not_found} = Bookmarks.bookmark(bob, secret_post)
    assert {:ok, _} = Bookmarks.bookmark(admin, secret_post)

    {:ok, deleted} = Forums.create_post(thread, alice, %{body: "gone"})
    {:ok, _} = Forums.delete_post(deleted, alice)
    assert {:error, :not_found} = Bookmarks.bookmark(bob, Repo.reload!(deleted))

    {:ok, hidden} = Forums.create_post(thread, alice, %{body: "flagged"})

    hidden =
      hidden |> Ecto.Changeset.change(hidden_at: DateTime.utc_now(:second)) |> Repo.update!()

    assert {:error, :not_found} = Bookmarks.bookmark(bob, hidden)
    # Its author still reads it.
    assert {:ok, _} = Bookmarks.bookmark(alice, hidden)

    queued = %Post{
      thread_id: thread.id,
      user_id: alice.id,
      body: "queued",
      queued_at: DateTime.utc_now(:second)
    }

    queued = Repo.insert!(queued)
    assert {:error, :not_found} = Bookmarks.bookmark(bob, queued)
  end

  test "a reminder fires once, as a notification", %{bob: bob, reply: reply, thread: thread} do
    {:ok, bookmark} = Bookmarks.bookmark(bob, reply)

    {:ok, _} =
      Bookmarks.update(bob, bookmark.id, %{"note" => "check this", "reminder" => "later_today"})

    assert Repo.reload!(bookmark).remind_at

    assert Bookmarks.run_due() == 0
    assert Bookmarks.run_due(in_seconds(4 * 3600)) == 1

    assert [%Notification{body: "check this", post_id: post_id, thread_id: thread_id} = n] =
             reminders(bob)

    assert {post_id, thread_id} == {reply.id, thread.id}
    assert n.url =~ "#post-#{reply.id}"
    assert [_] = Forums.notifications_for(bob)
    # Cleared: running again does nothing, and the bookmark stays.
    assert Repo.reload!(bookmark).remind_at == nil
    assert Bookmarks.run_due(in_seconds(8 * 3600)) == 0
    assert [_] = reminders(bob)
    assert [_] = Bookmarks.list(bob)
  end

  test "reminders are validated and can be cleared", %{bob: bob, reply: reply} do
    {:ok, bookmark} = Bookmarks.bookmark(bob, reply)

    past = FirestormWeb.LocalTime.to_input(in_seconds(-3600), 0)

    assert {:error, changeset} =
             Bookmarks.update(bob, bookmark.id, %{"reminder" => "custom", "custom_at" => past})

    assert "must be in the future" in errors_on(changeset).remind_at

    assert {:error, changeset} =
             Bookmarks.update(bob, bookmark.id, %{"reminder" => "custom", "custom_at" => ""})

    assert "needs a date and time" in errors_on(changeset).remind_at

    long = String.duplicate("x", 501)
    assert {:error, changeset} = Bookmarks.update(bob, bookmark.id, %{"note" => long})
    assert errors_on(changeset).note != []

    remind(bob, bookmark, in_seconds(3600))
    :ok = Bookmarks.clear_reminder(bob, bookmark.id)
    assert Repo.reload!(bookmark).remind_at == nil
    assert Bookmarks.run_due(in_seconds(7200)) == 0
  end

  test "presets are local times" do
    # A Wednesday, 15:00 UTC.
    now = ~U[2026-11-04 15:00:00Z]
    assert Bookmarks.remind_at("later_today", nil, 0, now) == ~U[2026-11-04 18:00:00Z]
    assert Bookmarks.remind_at("tomorrow", nil, 0, now) == ~U[2026-11-05 08:00:00Z]
    assert Bookmarks.remind_at("next_week", nil, 0, now) == ~U[2026-11-09 08:00:00Z]
    assert Bookmarks.remind_at("", nil, 0, now) == nil

    # 03:00 UTC on Thursday is still Wednesday evening at UTC-5 (offset 300).
    late = ~U[2026-11-05 03:00:00Z]
    assert Bookmarks.remind_at("tomorrow", nil, 300, late) == ~U[2026-11-05 13:00:00Z]

    assert Bookmarks.remind_at("custom", "2026-11-06T09:30", 300, late) ==
             ~U[2026-11-06 14:30:00Z]

    assert Bookmarks.remind_at("custom", "soon", 300, late) == nil
    assert FirestormWeb.LocalTime.to_input(~U[2026-11-06 14:30:00Z], 300) == "2026-11-06T09:30"
  end

  test "an unreadable post hides the bookmark and drops its reminder", %{
    admin: admin,
    bob: bob,
    reply: reply
  } do
    {:ok, bookmark} = Bookmarks.bookmark(bob, reply)
    remind(bob, bookmark, in_seconds(60))
    {:ok, _} = Forums.delete_post(reply, admin)

    assert Bookmarks.list(bob) == []
    assert Bookmarks.get(bob, bookmark.id) == nil
    assert Bookmarks.run_due(in_seconds(120)) == 0
    assert reminders(bob) == []
    assert Repo.reload!(bookmark).remind_at == nil

    # It's back with the post.
    {:ok, _} = Forums.restore_post(Repo.reload!(reply), admin)
    assert [_] = Bookmarks.list(bob)
  end

  test "a category restricted since hides it too", %{
    admin: admin,
    bob: bob,
    reply: reply,
    category: category
  } do
    {:ok, bookmark} = Bookmarks.bookmark(bob, reply)
    remind(bob, bookmark, in_seconds(60))
    {:ok, team} = Groups.create_group(%{name: "team"}, admin)
    {:ok, _} = Forums.update_category(category, %{role_ids: [team.id]}, admin)

    assert Bookmarks.list(bob) == []
    assert Bookmarks.run_due(in_seconds(120)) == 0
    assert reminders(bob) == []
  end

  test "split and merge carry bookmarks and reminders along", %{
    admin: admin,
    bob: bob,
    category: category,
    reply: reply,
    thread: thread
  } do
    {:ok, bookmark} = Bookmarks.bookmark(bob, reply)

    {:ok, split} =
      TopicTools.split(
        thread,
        [reply.id],
        {:new, %{"title" => "Split off", "category_id" => category.id}},
        admin
      )

    assert [%{post: %{thread: %{id: split_id}}}] = Bookmarks.list(bob)
    assert split_id == split.id

    target = thread_fixture(category, admin, %{title: "Target", body: "t"})
    {:ok, target} = TopicTools.merge(split, target, admin)
    assert [%{post: %{thread: %{id: target_id}}}] = Bookmarks.list(bob)
    assert target_id == target.id

    remind(bob, bookmark, in_seconds(60))
    assert Bookmarks.run_due(in_seconds(120)) == 1
    assert [%Notification{thread_id: ^target_id, url: url}] = reminders(bob)
    assert url =~ "/threads/#{target_id}#post-#{reply.id}"
  end

  test "the scheduler fires reminders that fell due while it was down", %{bob: bob, reply: reply} do
    {:ok, bookmark} = Bookmarks.bookmark(bob, reply)
    remind(bob, bookmark, in_seconds(60))
    Repo.update_all(Bookmark, set: [remind_at: in_seconds(-3600)])

    start_supervised!({TopicTimers.Scheduler, interval: 50})
    :sys.get_state(TopicTimers.Scheduler)

    assert [_] = reminders(bob)
    assert Repo.reload!(bookmark).remind_at == nil
  end

  test "in the account export, gone with the account", %{bob: bob, reply: reply} do
    {:ok, bookmark} = Bookmarks.bookmark(bob, reply)
    {:ok, _} = Bookmarks.update(bob, bookmark.id, %{"note" => "mine", "reminder" => "tomorrow"})

    assert [%{post_id: post_id, note: "mine", remind_at: %DateTime{}}] =
             AccountExport.build(bob).bookmarks

    assert post_id == reply.id

    {:ok, _} = AccountDeletion.delete_account(bob, bob.username)
    assert Repo.all(Bookmark) == []
  end
end
