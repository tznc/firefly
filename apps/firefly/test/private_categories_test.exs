defmodule Firefly.PrivateCategoriesTest do
  @moduledoc "Categories restricted to groups: no path may leak their threads."
  use Firefly.DataCase
  use Bamboo.Test, shared: true

  alias Firefly.{Accounts, Discussion, Groups, Messaging, Notifications, Repo}
  alias Firefly.Accounts.AccountExport
  alias Firefly.Discussion.{Mentions, Search}
  alias Firefly.Moderation.Posting
  alias Firefly.Rendering.Markdown

  alias Firefly.Discussion.Policy
  alias Firefly.Moderation.StaffAction
  alias Firefly.Notifications.Subscriptions

  setup do
    {:ok, _} = Notifications.start_link()

    admin = user("admin")
    {:ok, admin_role} = Groups.create_role("admin")
    {:ok, _} = Groups.add_role(admin, admin_role)

    insider = user("insider")
    outsider = user("outsider")
    {:ok, team} = Groups.create_group(%{name: "team"}, admin)
    {:ok, _} = Groups.add_member(team, "insider", admin)

    {:ok, public} = Discussion.create_category(%{title: "Public"})
    {:ok, secret} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})
    {:ok, inner} = Discussion.create_category(%{title: "Inner", parent_id: secret.id})

    public_thread = thread(public, insider, "Hello world", "public words")
    secret_thread = thread(secret, insider, "Launch plans", "classified words")
    inner_thread = thread(inner, insider, "Inner plans", "nested classified words")

    %{
      admin: admin,
      insider: insider,
      outsider: outsider,
      team: team,
      public: public,
      secret: secret,
      inner: inner,
      public_thread: public_thread,
      secret_thread: secret_thread,
      inner_thread: inner_thread
    }
  end

  defp user(name) do
    {:ok, user} =
      Accounts.create_user(%{username: name, name: name, email: "#{name}@example.com"})

    user
  end

  defp thread(category, user, title, body) do
    {:ok, thread} =
      Discussion.create_thread(category, user, %{title: title, body: body, tags: "plans"})

    flush()
    thread
  end

  defp flush, do: :sys.get_state(Notifications)
  defp titles(threads), do: threads |> Enum.map(& &1.title) |> Enum.sort()
  defp can?(user, action, resource), do: Bodyguard.permit?(Discussion, action, user, resource)

  describe "the policy" do
    test "restricted categories (and their subcategories) are for members and admins", ctx do
      for thread <- [ctx.secret_thread, ctx.inner_thread] do
        refute can?(nil, :view_thread, thread)
        refute can?(ctx.outsider, :view_thread, thread)
        assert can?(ctx.insider, :view_thread, thread)
        assert can?(ctx.admin, :view_thread, thread)
      end

      assert can?(nil, :view_thread, ctx.public_thread)
      refute can?(ctx.outsider, :view_category, ctx.inner)
      assert can?(ctx.insider, :view_category, ctx.inner)
    end

    test "a subcategory can add its own restriction to its parent's", ctx do
      {:ok, leads} = Groups.create_group(%{name: "leads"}, ctx.admin)
      {:ok, _} = Discussion.update_category(ctx.inner, %{role_ids: [leads.id]})

      refute can?(ctx.insider, :view_thread, ctx.inner_thread)
      {:ok, _} = Groups.add_member(leads, "outsider", ctx.admin)
      # Leads who aren't in the parent's group still can't get in.
      refute can?(ctx.outsider, :view_thread, ctx.inner_thread)
      {:ok, _} = Groups.add_member(leads, "insider", ctx.admin)
      assert can?(ctx.insider, :view_thread, ctx.inner_thread)
    end

    test "readable_threads/2 agrees with :view_thread", ctx do
      query = from(t in Firefly.Discussion.Thread, as: :thread)

      for user <- [nil, ctx.outsider, ctx.insider, ctx.admin] do
        readable = query |> Policy.readable_threads(user) |> Repo.all() |> titles()

        expected =
          [ctx.public_thread, ctx.secret_thread, ctx.inner_thread]
          |> Enum.filter(&can?(user, :view_thread, &1))
          |> titles()

        assert readable == expected
      end
    end

    test "thread_readers/2 agrees with :view_thread", ctx do
      {:ok, leads} = Groups.create_group(%{name: "leads"}, ctx.admin)
      {:ok, _} = Discussion.update_category(ctx.inner, %{role_ids: [leads.id]})
      {:ok, _} = Groups.add_member(leads, "outsider", ctx.admin)
      both = user("both")
      {:ok, _} = Groups.add_member(ctx.team, "both", ctx.admin)
      {:ok, _} = Groups.add_member(leads, "both", ctx.admin)
      users = [ctx.outsider, ctx.insider, ctx.admin, both]

      for thread <- [ctx.public_thread, ctx.secret_thread, ctx.inner_thread] do
        assert Policy.thread_readers(thread, users) ==
                 Enum.filter(users, &can?(&1, :view_thread, thread))
      end

      assert Policy.thread_readers(ctx.inner_thread, users) == [ctx.admin, both]
    end
  end

  describe "lists" do
    test "every thread list leaves out what the user can't read", ctx do
      %{outsider: outsider, insider: insider} = ctx
      {:ok, _} = Discussion.create_post(ctx.secret_thread, outsider, %{body: "sneaky reply"})
      Subscriptions.set_thread_level(outsider, ctx.secret_thread, "watching")
      Discussion.mark_thread_read(outsider, ctx.public_thread)
      {:ok, _} = Discussion.create_post(ctx.public_thread, insider, %{body: "more"})
      Discussion.mark_thread_read(outsider, ctx.secret_thread)
      {:ok, _} = Discussion.create_post(ctx.secret_thread, insider, %{body: "more"})
      tag = Discussion.get_tag!("plans")

      for {name, list} <- [
            latest: &Discussion.latest_threads/1,
            new: &Discussion.new_threads/1,
            unread: &Discussion.unread_threads/1,
            top: &Discussion.top_threads("all", &1),
            tag: &Discussion.tag_threads(tag, &1),
            watching: &Discussion.watched_threads/1,
            participating: &Discussion.participating_threads/1
          ] do
        threads = titles(list.(outsider))

        refute "Launch plans" in threads, "#{name} leaks"
        refute "Inner plans" in threads, "#{name} leaks"
      end

      assert "Launch plans" in titles(Discussion.latest_threads(insider))
      assert titles(Discussion.latest_threads(nil)) == ["Hello world"]
      assert titles(Discussion.top_threads("all", ctx.admin)) |> length() == 3
    end

    test "a public category's restricted subcategory stays out of its list", ctx do
      {:ok, sub} =
        Discussion.create_category(%{
          title: "Sub",
          parent_id: ctx.public.id,
          role_ids: [ctx.team.id]
        })

      thread(sub, ctx.insider, "Sub plans", "sub words")

      assert titles(Discussion.recent_threads(ctx.public, ctx.outsider)) == ["Hello world"]
      assert "Sub plans" in titles(Discussion.recent_threads(ctx.public, ctx.insider))
    end

    test "categories, tags and profiles", ctx do
      assert Enum.map(Discussion.list_categories(ctx.outsider), & &1.title) == ["Public"]
      assert Enum.map(Discussion.list_category_tree(nil), & &1.title) == ["Public"]

      [secret_tree] =
        ctx.insider |> Discussion.list_category_tree() |> Enum.filter(&(&1.title == "Secret"))

      assert secret_tree.restricted
      assert [%{title: "Inner", restricted: true}] = secret_tree.children

      assert [%{name: "plans", threads_count: 1}] = Discussion.list_tags(ctx.outsider)
      assert [%{name: "plans", threads_count: 3}] = Discussion.list_tags(ctx.insider)

      posts = Discussion.user_posts(ctx.insider, ctx.outsider, %{page: 1}).entries
      assert Enum.map(posts, & &1.body) == ["public words"]
      assert length(Discussion.user_posts(ctx.insider, ctx.insider, %{page: 1}).entries) == 3
      assert Discussion.user_last_post(ctx.insider, nil).body == "public words"
    end
  end

  test "search leaves restricted threads out", ctx do
    search = Search.parse("classified")

    assert Search.run(search, nil).entries == []
    assert Search.run(search, ctx.outsider).entries == []
    assert length(Search.run(search, ctx.insider).entries) == 2
    assert Search.run(Search.parse("category:secret"), ctx.outsider).entries == []
  end

  describe "notifications" do
    test "watchers of a category or tag without access get nothing", ctx do
      %{outsider: outsider, insider: insider} = ctx
      {:ok, _} = Subscriptions.set_category_level(outsider, ctx.secret, "watching")
      {:ok, _} = Subscriptions.set_tag_level(outsider, Discussion.get_tag!("plans"), "watching")
      reader = user("reader")
      {:ok, _} = Groups.add_member(ctx.team, "reader", ctx.admin)
      {:ok, _} = Subscriptions.set_category_level(reader, ctx.secret, "watching")

      thread(ctx.secret, insider, "Another secret", "shh")
      {:ok, _} = Discussion.create_post(ctx.secret_thread, insider, %{body: "a reply"})
      flush()

      assert Notifications.notifications_for(outsider) == []

      assert [%{kind: "new_post"}, %{kind: "new_thread"}] =
               Notifications.notifications_for(reader)

      refute_email_delivered_with(to: [nil: "outsider@example.com"])
    end

    test "a mention doesn't notify someone who can't read it", ctx do
      {:ok, _} = Discussion.create_post(ctx.secret_thread, ctx.insider, %{body: "hey @outsider"})
      flush()

      assert Notifications.notifications_for(ctx.outsider) == []
    end

    test "notifications disappear once their thread is out of reach", ctx do
      {:ok, _} = Discussion.create_post(ctx.public_thread, ctx.insider, %{body: "hey @outsider"})
      flush()
      assert [notification] = Notifications.notifications_for(ctx.outsider)
      assert Notifications.unread_notification_count(ctx.outsider) == 1

      {:ok, _} = Discussion.move_thread(ctx.public_thread, ctx.secret, ctx.admin)

      assert Notifications.notifications_for(ctx.outsider) == []
      assert Notifications.unread_notification_count(ctx.outsider) == 0
      assert Notifications.get_notification(ctx.outsider, notification.id) == nil
    end

    test "rows without a thread are shown only for messages and penalties", ctx do
      %{outsider: outsider} = ctx
      # A pre-thread_id row that quotes a (now restricted) thread's post.
      legacy = %{subject: "New post in: Launch plans", body: "classified", url: "/x"}
      {:ok, _} = Notifications.notify(outsider, legacy)

      {:ok, _} =
        Notifications.notify(outsider, %{
          kind: "silenced",
          subject: "Silenced",
          body: "why",
          url: "/"
        })

      {:ok, _} =
        Messaging.start_conversation(ctx.insider, %{
          recipients: "outsider",
          title: "Hi",
          body: "a message"
        })

      flush()

      assert [%{kind: "message"}, %{kind: "silenced"}] = Notifications.notifications_for(outsider)
      assert Notifications.unread_notification_count(outsider) == 2

      assert [%{kind: "silenced"}, %{kind: "message"}] =
               AccountExport.build(outsider).notifications
    end
  end

  test "replying (web, API, email) needs access to the thread", ctx do
    assert Posting.check(ctx.outsider, ctx.secret_thread) == {:error, :not_found}
    assert Posting.check(ctx.insider, ctx.secret_thread) == :ok
    assert Posting.message(:not_found) == "Thread not found."
  end

  test "#category links only for readers", ctx do
    body = "see #secret and #public"

    for viewer <- [nil, ctx.outsider] do
      html = Markdown.render(body, viewer)
      refute html =~ "/categories/#{ctx.secret.id}"
      assert html =~ "/categories/#{ctx.public.id}"
    end

    assert Markdown.render(body, ctx.insider) =~ "/categories/#{ctx.secret.id}"

    # Likewise with names resolved once for a page of posts
    refute Markdown.render(body, Mentions.refs([body], ctx.outsider)) =~
             "/categories/#{ctx.secret.id}"

    assert Markdown.render(body, Mentions.refs([body], ctx.insider)) =~
             "/categories/#{ctx.secret.id}"
  end

  test "the data export leaves out what the user can no longer read", ctx do
    {:ok, _} = Discussion.create_post(ctx.secret_thread, ctx.outsider, %{body: "my own words"})
    {:ok, _} = Discussion.create_post(ctx.public_thread, ctx.insider, %{body: "hi @outsider"})
    {:ok, _} = Subscriptions.set_category_level(ctx.outsider, ctx.secret, "tracking")
    {:ok, _} = Subscriptions.set_thread_level(ctx.outsider, ctx.secret_thread, "watching")
    flush()
    {:ok, _} = Discussion.move_thread(ctx.public_thread, ctx.inner, ctx.admin)

    export = AccountExport.build(ctx.outsider)

    # Their own words stay, without the restricted thread's title.
    assert [%{body: "my own words", thread_title: nil}] = export.posts
    assert export.notifications == []
    assert export.notification_levels.threads == []
    assert export.notification_levels.categories == []
    refute Jason.encode!(export) =~ "Launch plans"
    refute Jason.encode!(export) =~ "Secret"

    assert Enum.any?(AccountExport.build(ctx.insider).posts, &(&1.thread_title == "Launch plans"))
  end

  describe "staff log" do
    test "restricting a category and moving a thread into one are logged", ctx do
      {:ok, _} =
        Discussion.update_category(ctx.public, %{"role_ids" => ["#{ctx.team.id}"]}, ctx.admin)

      assert %{details: %{"restricted_to" => "team"}} =
               Repo.get_by!(StaffAction, action: "category.update")

      {:ok, other} = Discussion.create_category(%{title: "Other"})
      thread = thread(other, ctx.insider, "Moving", "body")
      {:ok, _} = Discussion.move_thread(thread, ctx.secret, ctx.admin)

      assert %{details: %{"restricted" => true, "to_category" => "Secret"}} =
               Repo.get_by!(StaffAction, action: "thread.move")
    end

    test "groups and their members", ctx do
      assert Repo.get_by(StaffAction,
               action: "role.create",
               target_type: "role",
               target_id: ctx.team.id
             )

      assert Repo.get_by(StaffAction, action: "role.grant", target_id: ctx.insider.id)

      assert {:error, :no_such_user} = Groups.add_member(ctx.team, "nobody", ctx.admin)
      assert {:error, :already_member} = Groups.add_member(ctx.team, "@Insider", ctx.admin)

      {:ok, _} = Groups.remove_member(ctx.team, ctx.insider, ctx.admin)
      assert Repo.get_by(StaffAction, action: "role.revoke", target_id: ctx.insider.id)
      refute can?(ctx.insider, :view_thread, ctx.secret_thread)

      admin_role = Repo.get_by!(Firefly.Groups.Role, name: "admin")
      assert {:error, :own_admin} = Groups.remove_member(admin_role, ctx.admin, ctx.admin)
    end

    test "a group restricting a category can't be deleted", ctx do
      {:ok, _} = Groups.remove_member(ctx.team, ctx.insider, ctx.admin)
      assert_raise Ecto.ConstraintError, fn -> Repo.delete(ctx.team) end
    end
  end
end
