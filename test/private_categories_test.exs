defmodule FirestormWeb.PrivateCategoriesTest do
  @moduledoc "Categories restricted to groups: no path may leak their threads."
  use FirestormWeb.DataCase
  use Bamboo.Test, shared: true

  alias FirestormWeb.{
    AccountExport,
    Forums,
    Groups,
    Markdown,
    Mentions,
    Notifications,
    Posting,
    Repo,
    Search
  }

  alias FirestormWeb.Forums.{Policy, StaffAction, Subscriptions}

  setup do
    {:ok, _} = Notifications.start_link()

    admin = user("admin")
    {:ok, admin_role} = Forums.create_role("admin")
    {:ok, _} = Forums.add_role(admin, admin_role)

    insider = user("insider")
    outsider = user("outsider")
    {:ok, team} = Groups.create_group(%{name: "team"}, admin)
    {:ok, _} = Groups.add_member(team, "insider", admin)

    {:ok, public} = Forums.create_category(%{title: "Public"})
    {:ok, secret} = Forums.create_category(%{title: "Secret", role_ids: [team.id]})
    {:ok, inner} = Forums.create_category(%{title: "Inner", parent_id: secret.id})

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
    {:ok, user} = Forums.create_user(%{username: name, name: name, email: "#{name}@example.com"})
    user
  end

  defp thread(category, user, title, body) do
    {:ok, thread} =
      Forums.create_thread(category, user, %{title: title, body: body, tags: "plans"})

    flush()
    thread
  end

  defp flush, do: :sys.get_state(Notifications)
  defp titles(threads), do: threads |> Enum.map(& &1.title) |> Enum.sort()
  defp can?(user, action, resource), do: Bodyguard.permit?(Forums, action, user, resource)

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
      {:ok, _} = Forums.update_category(ctx.inner, %{role_ids: [leads.id]})

      refute can?(ctx.insider, :view_thread, ctx.inner_thread)
      {:ok, _} = Groups.add_member(leads, "outsider", ctx.admin)
      # Leads who aren't in the parent's group still can't get in.
      refute can?(ctx.outsider, :view_thread, ctx.inner_thread)
      {:ok, _} = Groups.add_member(leads, "insider", ctx.admin)
      assert can?(ctx.insider, :view_thread, ctx.inner_thread)
    end

    test "readable_threads/2 agrees with :view_thread", ctx do
      query = from(t in Forums.Thread, as: :thread)

      for user <- [nil, ctx.outsider, ctx.insider, ctx.admin] do
        readable = query |> Policy.readable_threads(user) |> Repo.all() |> titles()

        expected =
          [ctx.public_thread, ctx.secret_thread, ctx.inner_thread]
          |> Enum.filter(&can?(user, :view_thread, &1))
          |> titles()

        assert readable == expected
      end
    end
  end

  describe "lists" do
    test "every thread list leaves out what the user can't read", ctx do
      %{outsider: outsider, insider: insider} = ctx
      {:ok, _} = Forums.create_post(ctx.secret_thread, outsider, %{body: "sneaky reply"})
      Subscriptions.set_thread_level(outsider, ctx.secret_thread, "watching")
      Forums.mark_thread_read(outsider, ctx.public_thread)
      {:ok, _} = Forums.create_post(ctx.public_thread, insider, %{body: "more"})
      Forums.mark_thread_read(outsider, ctx.secret_thread)
      {:ok, _} = Forums.create_post(ctx.secret_thread, insider, %{body: "more"})
      tag = Forums.get_tag!("plans")

      for {name, list} <- [
            latest: &Forums.latest_threads/1,
            new: &Forums.new_threads/1,
            unread: &Forums.unread_threads/1,
            top: &Forums.top_threads("all", &1),
            tag: &Forums.tag_threads(tag, &1),
            watching: &Forums.watched_threads/1,
            participating: &Forums.participating_threads/1
          ] do
        threads = titles(list.(outsider))

        refute "Launch plans" in threads, "#{name} leaks"
        refute "Inner plans" in threads, "#{name} leaks"
      end

      assert "Launch plans" in titles(Forums.latest_threads(insider))
      assert titles(Forums.latest_threads(nil)) == ["Hello world"]
      assert titles(Forums.top_threads("all", ctx.admin)) |> length() == 3
    end

    test "a public category's restricted subcategory stays out of its list", ctx do
      {:ok, sub} =
        Forums.create_category(%{
          title: "Sub",
          parent_id: ctx.public.id,
          role_ids: [ctx.team.id]
        })

      thread(sub, ctx.insider, "Sub plans", "sub words")

      assert titles(Forums.recent_threads(ctx.public, ctx.outsider)) == ["Hello world"]
      assert "Sub plans" in titles(Forums.recent_threads(ctx.public, ctx.insider))
    end

    test "categories, tags and profiles", ctx do
      assert Enum.map(Forums.list_categories(ctx.outsider), & &1.title) == ["Public"]
      assert Enum.map(Forums.list_category_tree(nil), & &1.title) == ["Public"]

      [secret_tree] =
        ctx.insider |> Forums.list_category_tree() |> Enum.filter(&(&1.title == "Secret"))

      assert secret_tree.restricted
      assert [%{title: "Inner", restricted: true}] = secret_tree.children

      assert [%{name: "plans", threads_count: 1}] = Forums.list_tags(ctx.outsider)
      assert [%{name: "plans", threads_count: 3}] = Forums.list_tags(ctx.insider)

      posts = Forums.user_posts(ctx.insider, ctx.outsider, %{page: 1}).entries
      assert Enum.map(posts, & &1.body) == ["public words"]
      assert length(Forums.user_posts(ctx.insider, ctx.insider, %{page: 1}).entries) == 3
      assert Forums.user_last_post(ctx.insider, nil).body == "public words"
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
      {:ok, _} = Subscriptions.set_tag_level(outsider, Forums.get_tag!("plans"), "watching")
      reader = user("reader")
      {:ok, _} = Groups.add_member(ctx.team, "reader", ctx.admin)
      {:ok, _} = Subscriptions.set_category_level(reader, ctx.secret, "watching")

      thread(ctx.secret, insider, "Another secret", "shh")
      {:ok, _} = Forums.create_post(ctx.secret_thread, insider, %{body: "a reply"})
      flush()

      assert Forums.notifications_for(outsider) == []
      assert [%{kind: "new_post"}, %{kind: "new_thread"}] = Forums.notifications_for(reader)
      refute_email_delivered_with(to: [nil: "outsider@example.com"])
    end

    test "a mention doesn't notify someone who can't read it", ctx do
      {:ok, _} = Forums.create_post(ctx.secret_thread, ctx.insider, %{body: "hey @outsider"})
      flush()

      assert Forums.notifications_for(ctx.outsider) == []
    end

    test "notifications disappear once their thread is out of reach", ctx do
      {:ok, _} = Forums.create_post(ctx.public_thread, ctx.insider, %{body: "hey @outsider"})
      flush()
      assert [notification] = Forums.notifications_for(ctx.outsider)
      assert Forums.unread_notification_count(ctx.outsider) == 1

      {:ok, _} = Forums.move_thread(ctx.public_thread, ctx.secret, ctx.admin)

      assert Forums.notifications_for(ctx.outsider) == []
      assert Forums.unread_notification_count(ctx.outsider) == 0
      assert Forums.get_notification(ctx.outsider, notification.id) == nil
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
    {:ok, _} = Forums.create_post(ctx.secret_thread, ctx.outsider, %{body: "my own words"})
    {:ok, _} = Forums.create_post(ctx.public_thread, ctx.insider, %{body: "hi @outsider"})
    {:ok, _} = Subscriptions.set_category_level(ctx.outsider, ctx.secret, "tracking")
    {:ok, _} = Subscriptions.set_thread_level(ctx.outsider, ctx.secret_thread, "watching")
    flush()
    {:ok, _} = Forums.move_thread(ctx.public_thread, ctx.inner, ctx.admin)

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
        Forums.update_category(ctx.public, %{"role_ids" => ["#{ctx.team.id}"]}, ctx.admin)

      assert %{details: %{"restricted_to" => "team"}} =
               Repo.get_by!(StaffAction, action: "category.update")

      {:ok, other} = Forums.create_category(%{title: "Other"})
      thread = thread(other, ctx.insider, "Moving", "body")
      {:ok, _} = Forums.move_thread(thread, ctx.secret, ctx.admin)

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

      admin_role = Repo.get_by!(Forums.Role, name: "admin")
      assert {:error, :own_admin} = Groups.remove_member(admin_role, ctx.admin, ctx.admin)
    end

    test "a group restricting a category can't be deleted", ctx do
      {:ok, _} = Groups.remove_member(ctx.team, ctx.insider, ctx.admin)
      assert_raise Ecto.ConstraintError, fn -> Repo.delete(ctx.team) end
    end
  end
end
