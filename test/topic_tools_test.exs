defmodule FirestormWeb.TopicToolsTest do
  use FirestormWeb.DataCase

  import FirestormWeb.Web.ConnCase,
    only: [user_fixture: 0, admin_fixture: 0, category_fixture: 1, thread_fixture: 3]

  alias FirestormWeb.{Forums, Posting, StaffLog, TopicTimers, TopicTools}
  alias FirestormWeb.Forums.{Notification, Post, StaffAction, Subscriptions, Thread, ThreadTimer}

  setup do
    admin = admin_fixture()
    alice = user_fixture()
    bob = user_fixture()
    category = category_fixture("Elixir")
    %{admin: admin, alice: alice, bob: bob, category: category}
  end

  # Sets a post's time, `seconds` ago.
  defp age(%Post{id: id}, seconds) do
    at = NaiveDateTime.add(NaiveDateTime.utc_now(), -seconds, :second)
    Repo.update_all(where(Post, id: ^id), set: [inserted_at: at])
  end

  defp first_post(thread),
    do:
      Repo.one(
        from(p in Post,
          where: p.thread_id == ^thread.id,
          order_by: [p.inserted_at, p.id],
          limit: 1
        )
      )

  defp bodies(thread) do
    Repo.all(
      from(p in Post,
        where: p.thread_id == ^thread.id,
        order_by: [p.inserted_at, p.id],
        select: p.body
      )
    )
  end

  defp log_entries(action), do: Repo.all(from(a in StaffAction, where: a.action == ^action))

  defp completely_read?(thread, user),
    do: Enum.find(Forums.latest_threads(user), &(&1.id == thread.id)).completely_read?

  describe "merge/3" do
    setup %{alice: alice, bob: bob, category: category} do
      # The source is older than the target: its first post must still not
      # take the target's place.
      source = thread_fixture(category, alice, %{title: "Source", body: "s1"})
      age(first_post(source), 300)
      {:ok, s2} = Forums.create_post(source, bob, %{body: "s2"})
      age(s2, 100)

      target = thread_fixture(category, bob, %{title: "Target", body: "t1"})
      age(first_post(target), 200)
      {:ok, _t2} = Forums.create_post(target, alice, %{body: "t2"})

      %{source: source, target: target}
    end

    test "moves every post, keeping the target's first post first", %{
      admin: admin,
      source: source,
      target: target
    } do
      assert {:ok, %Thread{id: id}} = TopicTools.merge(source, target, admin)
      assert id == target.id

      # s1 was older than t1: it's placed right after it; s2 falls in time.
      assert bodies(target) == ["t1", "s1", "s2", "t2"]
      assert bodies(source) == []

      stub = Repo.get!(Thread, source.id)
      assert stub.merged_into_id == target.id
      assert Thread.closed?(stub)
      assert Forums.get_thread_after_merges(source.id).id == target.id
    end

    test "the stub is on no list", %{
      admin: admin,
      alice: alice,
      category: category,
      source: source,
      target: target
    } do
      {:ok, _} = Forums.update_thread(source, %{tags: "otp"}, admin)
      {:ok, _} = TopicTools.merge(source, target, admin)

      for threads <- [
            Forums.latest_threads(nil),
            Forums.latest_threads(alice),
            Forums.list_threads(category),
            Forums.recent_threads(category),
            Forums.participating_threads(alice),
            elem(Forums.get_recent_threads_for_categories([category], nil), 1)[category.id]
          ] do
        assert Enum.map(threads, & &1.id) == [target.id]
      end

      assert Forums.list_tags() == []
    end

    test "is logged", %{admin: admin, source: source, target: target} do
      {:ok, _} = TopicTools.merge(source, target, admin)

      assert [%{target_id: id, details: details}] = log_entries("thread.merge")
      assert id == source.id
      assert details == %{"title" => "Source", "into" => "Target", "posts" => 2}
    end

    test "keeps read state: read both, read target only", %{
      admin: admin,
      alice: alice,
      bob: bob,
      source: source,
      target: target
    } do
      carol = user_fixture()
      {:ok, _} = Forums.mark_thread_read(alice, source)
      {:ok, _} = Forums.mark_thread_read(alice, target)
      {:ok, _} = Forums.mark_thread_read(carol, target)
      {:ok, _} = Forums.mark_thread_read(bob, source)
      {:ok, _} = TopicTools.merge(source, target, admin)

      read = fn user -> Forums.thread_read(user, target).last_read_post_id end

      [t1, s1, s2, t2] =
        Repo.all(
          from(p in Post,
            where: p.thread_id == ^target.id,
            order_by: [p.inserted_at, p.id],
            select: p.id
          )
        )

      # Alice read everything: still everything.
      assert read.(alice) == Enum.max([t1, s1, s2, t2])
      # Carol never saw the source's posts: they're unread for her.
      assert read.(carol) == Enum.min([s1, s2]) - 1
      # Bob read all of the source but only t1 of the target: up to t2.
      assert read.(bob) == t2 - 1
      assert Forums.thread_read(alice, source) == nil
    end

    test "combines notification levels", %{
      admin: admin,
      alice: alice,
      bob: bob,
      source: source,
      target: target
    } do
      carol = user_fixture()
      {:ok, _} = Subscriptions.set_thread_level(carol, source, "watching")
      {:ok, _} = Subscriptions.set_thread_level(bob, source, "muted")
      {:ok, _} = Subscriptions.set_thread_level(bob, target, "tracking")
      {:ok, _} = Subscriptions.set_thread_level(alice, source, "watching")
      {:ok, _} = Subscriptions.set_thread_level(alice, target, "normal")

      {:ok, _} = TopicTools.merge(source, target, admin)

      assert Subscriptions.thread_level(carol, target) == "watching"
      assert Subscriptions.thread_level(bob, target) == "tracking"
      assert Subscriptions.thread_level(alice, target) == "watching"
    end

    test "points notifications at the target", %{
      admin: admin,
      bob: bob,
      source: source,
      target: target
    } do
      post = first_post(source)

      {:ok, notification} =
        Forums.notify(
          bob,
          Notification.for_post("new_post", source, post, Forums.get_user!(post.user_id))
        )

      {:ok, _} = TopicTools.merge(source, target, admin)

      notification = Repo.get!(Notification, notification.id)
      assert notification.thread_id == target.id
      assert notification.url =~ "/threads/#{target.id}#post-#{post.id}"
      # Reading the target reads it.
      {:ok, _} = Forums.mark_thread_read(bob, Repo.get!(Thread, target.id))
      assert Repo.get!(Notification, notification.id).read_at
    end

    test "follows merges of merges", %{
      admin: admin,
      alice: alice,
      category: category,
      source: source,
      target: target
    } do
      {:ok, _} = TopicTools.merge(source, target, admin)
      third = thread_fixture(category, alice, %{title: "Third", body: "x"})
      {:ok, _} = TopicTools.merge(Repo.get!(Thread, target.id), third, admin)

      assert Repo.get!(Thread, source.id).merged_into_id == third.id
      assert Forums.get_thread_after_merges(source.id).id == third.id
    end

    test "refuses the same thread or a merged one", %{
      admin: admin,
      source: source,
      target: target
    } do
      assert {:error, :same_thread} = TopicTools.merge(source, source, admin)
      {:ok, _} = TopicTools.merge(source, target, admin)
      assert {:error, :merged} = TopicTools.merge(Repo.get!(Thread, source.id), target, admin)
      assert {:error, :merged} = TopicTools.merge(target, Repo.get!(Thread, source.id), admin)
    end
  end

  describe "split/4" do
    setup %{alice: alice, bob: bob, category: category} do
      thread = thread_fixture(category, alice, %{title: "Big", body: "op"})
      {:ok, r1} = Forums.create_post(thread, bob, %{body: "r1"})
      {:ok, r2} = Forums.create_post(thread, alice, %{body: "r2"})
      {:ok, r3} = Forums.create_post(thread, bob, %{body: "r3"})
      %{thread: thread, r1: r1, r2: r2, r3: r3}
    end

    test "to a new thread", %{
      admin: admin,
      bob: bob,
      alice: alice,
      thread: thread,
      r1: r1,
      r3: r3
    } do
      other = category_fixture("Other")
      {:ok, _} = Forums.mark_thread_read(alice, thread)

      assert {:ok, new} =
               TopicTools.split(
                 thread,
                 [r1.id, to_string(r3.id)],
                 {:new, %{"title" => "Offshoot", "category_id" => to_string(other.id)}},
                 admin
               )

      assert new.title == "Offshoot"
      assert new.category_id == other.id
      assert bodies(new) == ["r1", "r3"]
      assert bodies(thread) == ["op", "r2"]

      # Alice had read it all: the new thread is read too.
      assert Forums.thread_read(alice, new).last_read_post_id == r3.id
      assert completely_read?(new, alice)

      # Bob is told where his posts went; Alice wasn't moved.
      assert [%{kind: "moved", post_id: post_id, thread_id: thread_id}] =
               Forums.notifications_for(bob)

      assert post_id == r1.id and thread_id == new.id
      assert Forums.notifications_for(alice) == []

      assert [
               %{
                 target_id: id,
                 details: %{"to" => "Offshoot", "new_thread" => true, "posts" => 2}
               }
             ] =
               log_entries("thread.split")

      assert id == thread.id
    end

    test "into an existing thread", %{
      admin: admin,
      alice: alice,
      category: category,
      thread: thread,
      r2: r2
    } do
      target = thread_fixture(category, alice, %{title: "Target", body: "t1"})

      assert {:ok, %{id: id}} = TopicTools.split(thread, [r2.id], {:existing, target}, admin)
      assert id == target.id
      # r2 was older than the target's first post: placed right after it.
      assert bodies(target) == ["t1", "r2"]
    end

    test "never the first post, and needs posts of this thread", %{
      admin: admin,
      alice: alice,
      category: category,
      thread: thread,
      r1: r1
    } do
      new = {:new, %{"title" => "X", "category_id" => category.id}}
      other = thread_fixture(category, alice, %{title: "Other", body: "o"})

      assert {:error, :first_post} =
               TopicTools.split(thread, [first_post(thread).id, r1.id], new, admin)

      assert {:error, :no_posts} = TopicTools.split(thread, [], new, admin)
      assert {:error, :no_posts} = TopicTools.split(thread, [first_post(other).id], new, admin)

      assert {:error, :same_thread} =
               TopicTools.split(thread, [r1.id], {:existing, thread}, admin)

      assert {:error, %Ecto.Changeset{}} =
               TopicTools.split(
                 thread,
                 [r1.id],
                 {:new, %{"title" => "", "category_id" => category.id}},
                 admin
               )

      assert bodies(thread) == ["op", "r1", "r2", "r3"]
      assert log_entries("thread.split") == []
    end
  end

  describe "timers" do
    setup %{alice: alice, category: category} do
      %{thread: thread_fixture(category, alice, %{title: "Timed", body: "x"})}
    end

    defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(:second), seconds)

    test "close at a time, once", %{admin: admin, thread: thread} do
      {:ok, timer} =
        TopicTimers.set_timer(thread, %{action: "close", run_at: in_seconds(60)}, admin)

      assert TopicTimers.get_timer(thread).id == timer.id
      assert [%{details: %{"action" => "close"}}] = log_entries("thread.timer")

      # Not due yet.
      assert TopicTimers.run_due() == 0
      refute Repo.get!(Thread, thread.id).closed_at

      assert TopicTimers.run_due(in_seconds(61)) == 1
      assert Repo.get!(Thread, thread.id).closed_at
      assert TopicTimers.get_timer(thread) == nil
      assert [%{actor_id: actor_id, details: %{"timer" => true}}] = log_entries("thread.close")
      assert actor_id == admin.id

      # Running again does nothing.
      assert TopicTimers.run_due(in_seconds(120)) == 0
      assert length(log_entries("thread.close")) == 1
    end

    test "an action already done is a no-op", %{admin: admin, thread: thread} do
      {:ok, _} = TopicTimers.set_timer(thread, %{action: "open", run_at: in_seconds(60)}, admin)
      assert TopicTimers.run_due(in_seconds(61)) == 1
      assert log_entries("thread.open") == []
      assert TopicTimers.get_timer(thread) == nil
    end

    test "reopen and delete", %{admin: admin, thread: thread} do
      {:ok, thread} = Forums.close_thread(thread, true, admin)
      {:ok, _} = TopicTimers.set_timer(thread, %{action: "open", run_at: in_seconds(60)}, admin)
      TopicTimers.run_due(in_seconds(61))
      refute Repo.get!(Thread, thread.id).closed_at

      {:ok, _} = TopicTimers.set_timer(thread, %{action: "delete", run_at: in_seconds(60)}, admin)
      TopicTimers.run_due(in_seconds(61))
      refute Repo.get(Thread, thread.id)
    end

    test "one per thread, in the future, cancellable", %{admin: admin, thread: thread} do
      {:ok, _} = TopicTimers.set_timer(thread, %{action: "close", run_at: in_seconds(60)}, admin)
      {:ok, _} = TopicTimers.set_timer(thread, %{action: "delete", run_at: in_seconds(90)}, admin)
      assert [%ThreadTimer{action: "delete"}] = Repo.all(ThreadTimer)

      assert {:error, changeset} =
               TopicTimers.set_timer(thread, %{action: "close", run_at: in_seconds(-1)}, admin)

      assert "must be in the future" in errors_on(changeset).run_at

      assert {:error, _} =
               TopicTimers.set_timer(thread, %{action: "explode", run_at: in_seconds(60)}, admin)

      :ok = TopicTimers.cancel_timer(thread, admin)
      assert Repo.all(ThreadTimer) == []
      assert [_] = log_entries("thread.timer_cancel")
      # Nothing to cancel: not logged again.
      :ok = TopicTimers.cancel_timer(thread, admin)
      assert [_] = log_entries("thread.timer_cancel")
    end

    test "the scheduler runs due timers, including ones that fell due while it was down", %{
      admin: admin,
      thread: thread
    } do
      {:ok, _} = TopicTimers.set_timer(thread, %{action: "close", run_at: in_seconds(60)}, admin)
      # As if it fell due while the app was down.
      Repo.update_all(ThreadTimer, set: [run_at: in_seconds(-3600)])

      start_supervised!({TopicTimers.Scheduler, interval: 50})
      :sys.get_state(TopicTimers.Scheduler)

      assert Repo.get!(Thread, thread.id).closed_at
      assert Repo.all(ThreadTimer) == []
    end
  end

  describe "slow mode" do
    setup %{alice: alice, category: category} do
      %{thread: thread_fixture(category, alice, %{title: "Slow", body: "x"})}
    end

    test "one reply per interval, admins exempt", %{
      admin: admin,
      alice: alice,
      bob: bob,
      thread: thread
    } do
      assert Posting.check(bob, thread) == :ok
      {:ok, thread} = TopicTools.set_slow_mode(thread, 600, admin)
      assert thread.slow_mode_seconds == 600

      # Alice started it just now.
      assert {:error, {:slow_mode, wait}} = Posting.check(alice, thread)
      assert wait in 590..600

      assert Posting.message({:slow_mode, wait}) ==
               "This thread is in slow mode: you can reply again in 10 minutes."

      # Bob hasn't posted yet; then he has.
      assert Posting.check(bob, thread) == :ok
      {:ok, reply} = Forums.create_post(thread, bob, %{body: "hi"})
      assert {:error, {:slow_mode, _}} = Posting.check(bob, thread)
      age(reply, 601)
      assert Posting.check(bob, thread) == :ok

      {:ok, _} = Forums.create_post(thread, admin, %{body: "staff"})
      assert Posting.check(admin, thread) == :ok

      {:ok, thread} = TopicTools.set_slow_mode(thread, 0, admin)
      assert thread.slow_mode_seconds == nil
      assert Posting.check(alice, thread) == :ok

      assert [%{details: %{"seconds" => %{"before" => nil, "after" => 600}}}, _off] =
               Enum.sort_by(log_entries("thread.slow_mode"), & &1.id)
    end

    test "durations" do
      assert Posting.duration_text(1) == "1 second"
      assert Posting.duration_text(45) == "45 seconds"
      assert Posting.duration_text(61) == "2 minutes"
      assert Posting.duration_text(3600) == "1 hour"
      assert Posting.duration_text(3660) == "1 hour 1 minute"
      assert Posting.duration_text(7 * 86_400) == "7 days"
    end
  end

  test "new log actions are known" do
    for action <- ~w(thread.merge thread.split thread.timer thread.timer_cancel thread.slow_mode),
        do: assert(action in StaffLog.actions())
  end
end
