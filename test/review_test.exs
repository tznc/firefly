defmodule FirestormWeb.ReviewTest do
  use FirestormWeb.DataCase
  use Bamboo.Test, shared: true

  alias FirestormWeb.{Flags, Forums, Notifications, Penalties, Repo, Review}
  alias FirestormWeb.Forums.{Flag, Post, SiteSetting, StaffAction, Subscriptions, Thread, User}

  setup do
    {:ok, _} = Notifications.start_link()
    admin = user("admin")
    {:ok, role} = Forums.create_role("admin")
    {:ok, _} = Forums.add_role(admin, role)
    author = user("author")
    {:ok, category} = Forums.create_category(%{title: "Elixir"})
    {:ok, thread} = Forums.create_thread(category, author, %{title: "Pills", body: "first"})
    {:ok, reply} = Forums.create_post(thread, author, %{body: "buy pills"})
    flush()

    %{admin: admin, author: author, category: category, thread: thread, reply: reply}
  end

  defp user(name) do
    {:ok, user} = Forums.create_user(%{username: name, name: name, email: "#{name}@example.com"})
    user
  end

  defp flush, do: :sys.get_state(Notifications)

  defp flag_until_hidden(post) do
    for _ <- 1..3 do
      flagger = user("flagger#{System.unique_integer([:positive])}")
      {:ok, _} = Flags.flag_post(post, flagger, %{"reason" => "spam"})
    end

    Repo.get!(Post, post.id)
  end

  defp statuses(post),
    do: Flag |> where(post_id: ^post.id) |> select([f], f.status) |> Repo.all() |> Enum.uniq()

  defp logged?(action), do: Repo.exists?(from(a in StaffAction, where: a.action == ^action))

  describe "flagged posts" do
    test "are grouped per post with their flags", %{reply: reply} do
      flag_until_hidden(reply)

      assert [%Post{id: id, flags: flags}] = Review.flagged_posts()
      assert id == reply.id
      assert length(flags) == 3
      assert Review.pending_count() == 1
    end

    test "agree and hide: the post stays hidden", %{reply: reply, admin: admin} do
      Review.subscribe()
      reply = flag_until_hidden(reply)
      assert_receive :review_changed

      assert {:ok, _} = Review.agree(reply, admin, :hide)
      assert statuses(reply) == ["agreed"]
      assert Repo.get!(Post, reply.id).hidden_at
      reviewers = Flag |> where(post_id: ^reply.id) |> select([f], f.reviewed_by_id) |> Repo.all()
      assert Enum.uniq(reviewers) == [admin.id]
      assert %{details: %{"decision" => "hide"}} = Repo.get_by!(StaffAction, action: "flag.agree")
      assert Review.pending_count() == 0
      assert {:error, :no_pending_flags} = Review.agree(reply, admin, :hide)
    end

    test "agree and delete: a reply is soft-deleted, a first post takes its thread", ctx do
      {:ok, _} = Review.agree(flag_until_hidden(ctx.reply), ctx.admin, :delete)
      assert Repo.get!(Post, ctx.reply.id).deleted_at
      assert logged?("post.delete") and logged?("flag.agree")

      [first] = Repo.preload(ctx.thread, :posts, force: true).posts |> Enum.take(1)
      {:ok, _} = Review.agree(flag_until_hidden(first), ctx.admin, :delete)
      refute Repo.get(Thread, ctx.thread.id)
    end

    test "agree and silence the author", %{reply: reply, admin: admin} do
      params = %{"duration" => "1w", "reason" => "spamming"}
      {:ok, _} = Review.agree(flag_until_hidden(reply), admin, {:silence, params})

      assert User.silenced?(Repo.get!(User, reply.user_id))
      assert logged?("user.silence")
      assert Repo.get!(Post, reply.id).hidden_at
    end

    test "what a decision does outside the database waits for its commit", ctx do
      %{reply: reply, admin: admin, author: author} = ctx
      Forums.subscribe("forums:thread:#{reply.thread_id}")
      params = %{"duration" => "1w", "reason" => "spamming"}

      assert {:error, :rolled_back} =
               Repo.transact(fn ->
                 {:ok, _, _} = Penalties.penalize_unannounced(:silence, author, admin, params)
                 {:ok, _, _} = Forums.delete_post_unannounced(reply, admin)
                 {:error, :rolled_back}
               end)

      refute_received {:post_deleted, _}
      assert Forums.notifications_for(author) == []
      assert_no_emails_delivered()
      refute Repo.get!(User, author.id).silenced_until
      refute Repo.get!(Post, reply.id).deleted_at

      # Committed, the decision announces itself.
      {:ok, _} = Review.agree(flag_until_hidden(reply), admin, {:silence, params})
      assert "silenced" in Enum.map(Forums.notifications_for(author), & &1.kind)
    end

    test "a failed decision changes nothing", %{reply: reply, admin: admin} do
      reply = flag_until_hidden(reply)
      assert {:error, :no_reason} = Review.agree(reply, admin, {:silence, %{"duration" => "1w"}})
      assert statuses(reply) == ["pending"]
      refute logged?("flag.agree")
    end

    test "disagree: shown again, flaggers aren't told", %{reply: reply, admin: admin} do
      reply = flag_until_hidden(reply)
      {:ok, _} = Review.disagree(reply, admin)

      refute Repo.get!(Post, reply.id).hidden_at
      assert statuses(reply) == ["disagreed"]
      assert logged?("flag.disagree")

      for flag <- Repo.all(from(f in Flag, where: f.post_id == ^reply.id, preload: :user)),
          do: assert(Forums.notifications_for(flag.user) == [])
    end

    test "defer: the flags are set aside, the post stays as it is", %{reply: reply, admin: admin} do
      reply = flag_until_hidden(reply)
      {:ok, _} = Review.defer(reply, admin)

      assert Repo.get!(Post, reply.id).hidden_at
      assert statuses(reply) == ["deferred"]
      assert logged?("flag.defer")
    end
  end

  describe "posts awaiting approval" do
    setup %{category: category} do
      Repo.insert!(%SiteSetting{key: "approve_new_user_posts", value: "1"})
      watcher = user("watcher")
      {:ok, _} = Subscriptions.set_category_level(watcher, category, "watching")
      %{watcher: watcher}
    end

    test "a new user's first thread waits, unseen and unannounced, until approved", ctx do
      newbie = user("newbie")
      assert Forums.approval_required?(newbie)
      refute Forums.approval_required?(ctx.admin)

      {:ok, thread} =
        Forums.create_thread(ctx.category, newbie, %{title: "Hello", body: "hi @watcher"})

      flush()
      [post] = thread.posts
      assert Post.queued?(post)

      refute thread.id in Enum.map(Forums.latest_threads(ctx.watcher), & &1.id)
      refute Bodyguard.permit?(Forums, :view_thread, ctx.watcher, thread)
      assert Bodyguard.permit?(Forums, :view_thread, newbie, thread)
      assert Bodyguard.permit?(Forums, :view_thread, ctx.admin, thread)
      assert Forums.notifications_for(ctx.watcher) == []
      assert [%{first?: true}] = Review.queued_posts()

      {:ok, _} = Review.approve(post, ctx.admin)
      flush()

      assert thread.id in Enum.map(Forums.latest_threads(ctx.watcher), & &1.id)
      # Announced now: the mention wins over the new-thread notification.
      assert [%{kind: "mentioned"}] = Forums.notifications_for(ctx.watcher)
      assert logged?("post.approve")
      assert {:error, :not_queued} = Review.approve(post, ctx.admin)

      # Approved once, they post freely.
      refute Forums.approval_required?(newbie)
    end

    test "a queued reply is rejected with a reason", ctx do
      newbie = user("newbie")
      {:ok, reply} = Forums.create_post(ctx.thread, newbie, %{body: "spam reply"})
      flush()
      assert Post.queued?(reply)
      assert Forums.notifications_for(ctx.author) == []

      assert {:error, :reason_required} = Review.reject(reply, ctx.admin, " ")
      {:ok, _} = Review.reject(reply, ctx.admin, "Off-topic")

      assert Repo.get!(Post, reply.id).deleted_at
      assert [%{kind: "post_rejected", body: "Off-topic"}] = Forums.notifications_for(newbie)

      assert %{details: %{"reason" => "Off-topic"}} =
               Repo.get_by!(StaffAction, action: "post.reject")

      assert Review.queued_posts() == []
    end

    test "a queued reply's content stays out of the API and channels", ctx do
      {:ok, reply} = Forums.create_post(ctx.thread, user("newbie"), %{body: "spam reply"})
      queued = %{reply | oembeds: [{"https://spam.example", %{}}]}

      assert %{body: "", body_html: "", oembeds: [], queued: true} =
               FirestormWeb.Web.Api.V1.PostJSON.data(queued)

      refute Post.readable_by?(reply, nil)
      refute Post.readable_by?(reply, ctx.author)
      assert Post.readable_by?(reply, Repo.get!(User, reply.user_id))
      assert Post.readable_by?(reply, ctx.admin)
    end

    test "approved replies are unread for those who opened the thread meanwhile", ctx do
      %{watcher: watcher, thread: thread} = ctx
      {:ok, _} = Forums.mark_thread_read(watcher, thread)
      {:ok, reply} = Forums.create_post(thread, user("newbie"), %{body: "a reply"})

      # Queued: not unread, and not on the Unread list.
      refute thread.id in Enum.map(Forums.unread_threads(watcher), & &1.id)
      {:ok, _} = Forums.mark_thread_read(watcher, thread)

      {:ok, _} = Review.approve(reply, ctx.admin)
      assert [%{id: id, unread_count: 1}] = Forums.unread_threads(watcher)
      assert id == thread.id
    end

    test "authors can't edit a post while it's queued", ctx do
      newbie = user("newbie")
      {:ok, reply} = Forums.create_post(ctx.thread, newbie, %{body: "benign"})
      params = %{post: reply, thread: ctx.thread}

      refute Bodyguard.permit?(Forums, :edit_post, newbie, params)
      assert Bodyguard.permit?(Forums, :edit_post, ctx.admin, params)
      # Deleting it is still theirs to do.
      assert Bodyguard.permit?(Forums, :delete_post, newbie, params)

      {:ok, _} = Review.approve(reply, ctx.admin)
      approved = Repo.get!(Post, reply.id)
      assert Bodyguard.permit?(Forums, :edit_post, newbie, %{params | post: approved})
    end

    test "only the author and admins of a queued thread are notified readers", ctx do
      newbie = user("newbie")
      {:ok, thread} = Forums.create_thread(ctx.category, newbie, %{title: "Hi", body: "hi"})
      users = [ctx.watcher, newbie, ctx.admin]

      assert Forums.Policy.thread_readers(thread, users) == [newbie, ctx.admin]

      assert Forums.Policy.thread_readers(thread, users) ==
               Enum.filter(users, &Bodyguard.permit?(Forums, :view_thread, &1, thread))
    end

    test "queued posts know which are first posts", ctx do
      {:ok, thread} = Forums.create_thread(ctx.category, user("one"), %{title: "T", body: "t"})
      {:ok, reply} = Forums.create_post(ctx.thread, user("two"), %{body: "reply"})
      [first] = thread.posts

      assert Review.queued_posts() |> Enum.map(&{&1.id, &1.first?}) |> Enum.sort() ==
               Enum.sort([{first.id, true}, {reply.id, false}])
    end

    test "approve then a stale reject: the reject has nothing to do", ctx do
      newbie = user("newbie")
      {:ok, thread} = Forums.create_thread(ctx.category, newbie, %{title: "Hi", body: "hi"})
      [post] = thread.posts
      stale = Repo.preload(post, [:thread, :user])

      {:ok, _} = Review.approve(post, ctx.admin)
      assert {:error, :not_queued} = Review.reject(stale, ctx.admin, "Spam")
      assert Repo.get(Thread, thread.id)
      refute logged?("post.reject")
    end

    test "rejecting twice: once only, without crashing", ctx do
      newbie = user("newbie")
      {:ok, thread} = Forums.create_thread(ctx.category, newbie, %{title: "Hi", body: "hi"})
      {:ok, reply} = Forums.create_post(ctx.thread, newbie, %{body: "spam reply"})
      Forums.subscribe("forums:category:#{ctx.category.id}")

      for post <- [hd(thread.posts), reply] do
        assert {:ok, _} = Review.reject(post, ctx.admin, "Spam")
        assert {:error, :not_queued} = Review.reject(post, ctx.admin, "Spam")
      end

      # A rejected thread is deleted like any other: pages hear of it.
      assert_receive {:thread_deleted, %Thread{id: thread_id}}
      assert thread_id == thread.id
      assert length(Forums.notifications_for(newbie)) == 2
      assert Repo.aggregate(where(StaffAction, action: "post.reject"), :count) == 2
    end

    test "a rejected thread is deleted", ctx do
      newbie = user("newbie")
      {:ok, thread} = Forums.create_thread(ctx.category, newbie, %{title: "Nope", body: "spam"})

      {:ok, _} = Review.reject(hd(thread.posts), ctx.admin, "Spam")
      refute Repo.get(Thread, thread.id)
      assert [%{kind: "post_rejected", subject: subject}] = Forums.notifications_for(newbie)
      assert subject =~ ~s(thread "Nope")
    end
  end
end
