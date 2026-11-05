defmodule FireflyWeb.StaffAdminTest do
  use FireflyWeb.ConnCase
  # Password resets and test emails are emailed; approvals notify.
  import Swoosh.TestAssertions

  # Mail is sent from other processes (the notifications process, LiveViews).
  setup :set_swoosh_global

  defmodule RefusingMailer do
    @moduledoc false
    # An API adapter's answer to a bad key.
    use Swoosh.Adapter

    def deliver(_email, _config),
      do:
        {:error,
         {401, %{"errors" => [%{"message" => "The provided authorization grant is invalid"}]}}}
  end

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest, only: [live: 2]

  alias Firefly.{Accounts, Discussion, Groups, Repo, SiteSettings}
  alias Firefly.Accounts.{User, UserIPs}
  alias Firefly.Moderation.{Screening, StaffAction}

  setup do
    on_exit(&SiteSettings.clear_cache/0)
    %{admin: admin_fixture(%{username: "boss"}), member: user_fixture(%{username: "member"})}
  end

  defp moderator_fixture do
    user = user_fixture(%{username: "mod"})
    {:ok, _} = Groups.add_role(user, Groups.staff_group("moderator"))
    user
  end

  defp actions, do: Repo.all(from(a in StaffAction, order_by: a.id, select: a.action))

  describe "who gets in" do
    @admin_pages ~w(/staff /staff/users /staff/categories /staff/emails /staff/screening)

    test "visitors and members are turned away from every admin page", %{
      conn: conn,
      member: member
    } do
      for path <- @admin_pages ++ ["/staff/users/#{member.id}"] do
        conn |> visit(path) |> assert_path(~p"/categories")

        conn
        |> log_in_as(member)
        |> visit(path)
        |> assert_path(~p"/")
        |> assert_has("#flash-error", text: "You are not allowed to do that.")
      end
    end

    test "moderators get the moderation pages only", %{conn: conn, member: member} do
      conn = log_in_as(conn, moderator_fixture())

      conn
      |> visit(~p"/staff")
      |> assert_has("#staff-nav a", text: "Users")
      |> assert_has("#staff-nav a", text: "Screening")
      |> assert_has("#staff-nav a", text: "Review")
      |> refute_has("#staff-nav a", text: "Site settings")
      |> refute_has("#staff-nav a", text: "Categories")

      conn
      |> visit(~p"/staff/users/#{member.id}")
      |> assert_has("#penalty-form")
      |> refute_has("#account-form")
      |> refute_has("#danger-zone")
      |> refute_has("#impersonate")

      for path <- ~w(/staff/categories /staff/emails /staff/settings) do
        conn |> visit(path) |> assert_path(~p"/")
      end
    end

    test "the old /admin goes to the staff admin", %{conn: conn, admin: admin} do
      assert redirected_to(get(conn, "/admin")) == "/staff"
      assert redirected_to(get(conn, "/admin/forums/category")) == "/staff"
      conn |> log_in_as(admin) |> visit("/admin") |> assert_path(~p"/staff")
    end
  end

  describe "the admin home" do
    test "lists the sections and searches pages and settings", %{conn: conn, admin: admin} do
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff")
      |> assert_has("h2", text: "People")
      |> assert_has("#attention-pending", text: "0")
      |> fill_in("Search admin pages and settings", with: "screened spam")
      |> assert_has("#admin-search-pages a", text: "Screening")
      |> visit(~p"/staff?q=approve new accounts")
      |> assert_has("#admin-search-settings a", text: "Staff approve new accounts")
      |> visit(~p"/staff?q=zzzzzz")
      |> assert_has("#admin-search-results", text: "Nothing matches")
    end
  end

  describe "the users list" do
    test "filters, searches and approves", %{conn: conn, admin: admin} do
      {:ok, _} = SiteSettings.update(%{"must_approve_users" => "true"}, admin)

      {:ok, pending} =
        Accounts.register_user(%{
          username: "newbie",
          email: "newbie@example.com",
          password: "s3cret-password"
        })

      :ok = UserIPs.record(pending, "192.0.2.44")

      session =
        conn
        |> log_in_as(admin)
        |> visit(~p"/staff/users")
        |> assert_has("#users td", text: "member")
        |> click_link("#filter-pending", "Waiting for approval")
        |> assert_has("#users td", text: "newbie")
        |> refute_has("#users td", text: "member")

      session
      |> visit(~p"/staff/users?q=192.0.2.44")
      |> assert_has("#users td", text: "newbie")
      |> visit(~p"/staff/users?filter=staff")
      |> assert_has("#users td", text: "boss")
      |> refute_has("#users td", text: "newbie")

      session
      |> visit(~p"/staff/users?filter=pending")
      |> click_button("#user-#{pending.id} button", "Approve")
      |> assert_has("#flash-info", text: "Approved @newbie.")

      refute User.pending_approval?(Accounts.get_user!(pending.id))
    end
  end

  describe "a user's admin page" do
    test "edits the account and sends a reset and a notice", %{
      conn: conn,
      admin: admin,
      member: member
    } do
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/users/#{member.id}")
      |> within("#account-form", fn session ->
        session
        |> fill_in("Email", with: "changed@example.com")
        |> click_button("Save account")
      end)
      |> assert_has("#flash-info", text: "Account saved.")
      |> assert_has("#account-email", text: "changed@example.com")
      |> click_button("Send password reset")
      |> assert_has("#flash-info", text: "A password reset link was emailed to them.")
      |> within("#notice-form", fn session ->
        session
        |> fill_in("Send a notice: subject", with: "Please read the guidelines")
        |> click_button("Send notice")
      end)
      |> assert_has("#notifications li", text: "Please read the guidelines")

      assert_email_sent(to: "changed@example.com")
      assert ["user.edit", "user.password_reset", "notification.send"] = actions()
    end

    test "penalizes, sets trust and roles", %{conn: conn, admin: admin, member: member} do
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/users/#{member.id}")
      |> within("#penalty-form", fn session ->
        session
        |> select("Penalty", option: "Silence (can read, can't post)")
        |> fill_in("Reason (they see it)", with: "Cool off")
        |> click_button("Apply penalty")
      end)
      |> assert_has("#silenced", text: "Cool off")
      |> click_button("Lift silence")
      |> refute_has("#silenced")
      |> click_button("Grant moderator")
      |> assert_has("#user-badges", text: "moderator")

      assert Accounts.moderator?(member)
      assert ["user.silence", "user.unsilence", "role.grant"] = actions()
    end

    test "shows the addresses it used and other accounts there", %{
      conn: conn,
      admin: admin,
      member: member
    } do
      other = user_fixture(%{username: "sockpuppet"})
      :ok = UserIPs.record(member, "203.0.113.9")
      :ok = UserIPs.record(other, "203.0.113.9")

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/users/#{member.id}")
      |> assert_has("#ips a", text: "203.0.113.9")
      |> assert_has("#sharing a", text: "@sockpuppet")
    end

    test "anonymizes, deletes and merges", %{conn: conn, admin: admin, member: member} do
      gone = user_fixture(%{username: "gone"})
      dupe = user_fixture(%{username: "dupe"})
      conn = log_in_as(conn, admin)

      conn
      |> visit(~p"/staff/users/#{gone.id}")
      |> click_button("Delete with posts")
      |> assert_path(~p"/staff/users")
      |> assert_has("#flash-info", text: "The account and its posts were deleted.")

      assert User.deleted?(Accounts.get_user!(gone.id))

      conn
      |> visit(~p"/staff/users/#{dupe.id}")
      |> within("#merge-form", fn session ->
        session
        |> fill_in("Account to merge into", with: "@MEMBER")
        |> click_button("Merge into")
      end)
      |> assert_path(~p"/staff/users/#{member.id}")

      refute Accounts.get_user(dupe.id)

      conn
      |> visit(~p"/staff/users/#{member.id}")
      |> click_button("Anonymize")
      |> assert_path(~p"/staff/users")

      assert ["user.delete", "user.merge", "user.anonymize"] = actions()
    end

    test "staff accounts can't be removed or impersonated", %{conn: conn, admin: admin} do
      other_admin = admin_fixture(%{username: "chief"})

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/users/#{other_admin.id}")
      |> refute_has("#impersonate")
      |> click_button("Anonymize")
      |> assert_has("#flash-error", text: "Staff accounts can't be changed that way")

      refute User.deleted?(Accounts.get_user!(other_admin.id))
    end
  end

  describe "impersonation" do
    test "an admin sees the site as a member, with a banner, and comes back", ctx do
      %{conn: conn, admin: admin, member: member} = ctx

      conn = conn |> log_in_as(admin) |> post(~p"/staff/users/#{member.id}/impersonate")
      assert redirected_to(conn) == "/"
      assert get_session(conn, :current_user) == member.id
      assert get_session(conn, :impersonator_id) == admin.id

      conn
      |> recycle()
      |> visit(~p"/")
      |> assert_has("#impersonation-banner", text: "You're seeing the site as @member.")
      |> refute_has("nav a", text: "Admin")

      back = conn |> recycle() |> delete(~p"/impersonate")
      assert redirected_to(back) == "/staff/users/#{member.id}"
      assert get_session(back, :current_user) == admin.id
      refute get_session(back, :impersonator_id)

      assert ["user.impersonate", "user.impersonate_stop"] = actions()
    end

    test "admins can't be impersonated, and members can't impersonate", ctx do
      %{conn: conn, admin: admin, member: member} = ctx
      other_admin = admin_fixture()

      denied = conn |> log_in_as(admin) |> post(~p"/staff/users/#{other_admin.id}/impersonate")
      assert redirected_to(denied) == "/staff/users"
      assert get_session(denied, :current_user) == admin.id

      refused = conn |> log_in_as(member) |> post(~p"/staff/users/#{admin.id}/impersonate")
      assert redirected_to(refused) == "/"
      assert actions() == []
    end
  end

  describe "the categories admin" do
    test "sets group permissions and defaults", %{conn: conn, admin: admin} do
      first = category_fixture("Alpha")
      {:ok, group} = Groups.create_group(%{"name" => "insiders"}, admin)

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/categories")
      |> click_button("#category-#{first.id} button", "Permissions and defaults")
      |> within("#permissions-#{first.id}", fn session ->
        session
        |> select("insiders", option: "Read only")
        |> click_button("Save permissions")
      end)
      |> assert_has("#category-#{first.id}", text: "restricted")
      |> within("#defaults-#{first.id}", fn session ->
        session
        |> select("New members' notification level", option: "Watching")
        |> click_button("Save default")
      end)
      |> assert_has("#category-#{first.id}", text: "default: Watching")

      assert [{%{id: id}, "readonly"}] = Discussion.category_permissions(first)
      assert id == group.id
      assert Discussion.get_category!(first.id).default_notification_level == "watching"
    end
  end

  describe "reordering categories" do
    setup %{admin: admin} do
      alpha = category_fixture("Alpha")
      beta = category_fixture("Beta")
      {:ok, child} = Discussion.create_category(%{title: "Child", parent_id: alpha.id})
      other_admin = admin_fixture(%{username: "other"})
      %{alpha: alpha, beta: beta, child: child, admin: admin, other_admin: other_admin}
    end

    test "a drop moves a category, and other staff on the page see it", context do
      %{conn: conn, admin: admin, beta: beta, child: child} = context
      {:ok, view, _html} = live(log_in_as(conn, admin), ~p"/staff/categories")

      {:ok, watcher, _html} =
        live(log_in_as(build_conn(), context.other_admin), ~p"/staff/categories")

      Phoenix.LiveViewTest.render_hook(view, "place", %{
        "id" => beta.id,
        "parent_id" => nil,
        "index" => 0
      })

      Phoenix.LiveViewTest.assert_reply(view, %{ok: true})
      assert order(watcher) == ["Beta", "Alpha", "Child"]

      # Into another parent: Child goes under Beta.
      Phoenix.LiveViewTest.render_hook(view, "place", %{
        "id" => child.id,
        "parent_id" => beta.id,
        "index" => 0
      })

      Phoenix.LiveViewTest.assert_reply(view, %{ok: true})
      assert Discussion.get_category!(child.id).parent_id == beta.id

      assert watcher
             |> Phoenix.LiveViewTest.element("#subcategories-#{beta.id}")
             |> Phoenix.LiveViewTest.render() =~ "Child"

      assert Repo.all(
               from(a in StaffAction, where: a.action == "category.update", select: a.actor_id)
             ) ==
               [admin.id, admin.id]
    end

    test "a drop the structure doesn't allow is refused and nothing moves", context do
      %{conn: conn, admin: admin, alpha: alpha, beta: beta} = context
      {:ok, view, _html} = live(log_in_as(conn, admin), ~p"/staff/categories")

      # Alpha has a subcategory, so it can't become one.
      html =
        Phoenix.LiveViewTest.render_hook(view, "place", %{
          "id" => alpha.id,
          "parent_id" => beta.id,
          "index" => 0
        })

      Phoenix.LiveViewTest.assert_reply(view, %{ok: false})
      assert html =~ "That category can&#39;t go there."
      assert Discussion.get_category!(alpha.id).parent_id == nil

      # A category that's gone, or a malformed drop.
      Phoenix.LiveViewTest.render_hook(view, "place", %{
        "id" => -1,
        "parent_id" => nil,
        "index" => 0
      })

      Phoenix.LiveViewTest.assert_reply(view, %{ok: false})
      assert actions() == []
    end

    test "an admin demoted with the page open can't reorder from it", context do
      %{conn: conn, admin: admin, beta: beta} = context
      {:ok, view, _html} = live(log_in_as(conn, admin), ~p"/staff/categories")
      {:ok, _} = Groups.remove_member(Groups.staff_group("admin"), admin, context.other_admin)

      html =
        Phoenix.LiveViewTest.render_hook(view, "place", %{
          "id" => beta.id,
          "parent_id" => nil,
          "index" => 0
        })

      Phoenix.LiveViewTest.assert_reply(view, %{ok: false})
      assert html =~ "You are not allowed to do that."
      refute "category.update" in actions()
    end

    test "members and moderators never get the page", %{conn: conn} do
      for user <- [user_fixture(), moderator_fixture()] do
        assert {:error, {:live_redirect, %{to: "/"}}} =
                 live(log_in_as(conn, user), ~p"/staff/categories")
      end
    end
  end

  # Category titles in the order the page lists them.
  defp order(view) do
    html = view |> Phoenix.LiveViewTest.element("#categories") |> Phoenix.LiveViewTest.render()
    for [_, title] <- Regex.scan(~r/data-label="([^"]+)"/, html), do: title
  end

  describe "the emails admin" do
    test "sends a test email, shows the log and previews templates", %{conn: conn, admin: admin} do
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/emails?tab=test")
      |> assert_has("#mail-adapter", text: "Mailer: Test")
      |> fill_in("Send to", with: "ops@example.com")
      |> click_button("Send test email")
      |> assert_has("#flash-info", text: "Test email sent to ops@example.com with Test.")
      |> visit(~p"/staff/emails")
      |> assert_has("#email-log td", text: "ops@example.com")
      |> assert_has("#email-log td", text: "test_email")
      |> visit(~p"/staff/emails?status=failed")
      |> refute_has("#email-log td", text: "ops@example.com")
      |> visit(~p"/staff/emails?tab=previews&preview=digest")
      |> assert_has("#preview-subject", text: "Summary since")
      |> assert_has("#preview-html[sandbox]")

      assert_email_sent(to: "ops@example.com")
    end

    test "a failed test email shows the adapter's error", %{conn: conn, admin: admin} do
      config = Application.get_env(:firefly, Firefly.Mailer)
      Application.put_env(:firefly, Firefly.Mailer, adapter: RefusingMailer)
      on_exit(fn -> Application.put_env(:firefly, Firefly.Mailer, config) end)

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/emails?tab=test")
      |> fill_in("Send to", with: "ops@example.com")
      |> click_button("Send test email")
      |> assert_has("#flash-error", text: "couldn't send it: HTTP 401")
      |> assert_has("#flash-error", text: "The provided authorization grant is invalid")
      |> visit(~p"/staff/emails?status=failed")
      |> assert_has("#email-log td", text: "ops@example.com")
    end
  end

  describe "screening" do
    test "staff add and remove screened entries", %{conn: conn} do
      conn
      |> log_in_as(moderator_fixture())
      |> visit(~p"/staff/screening?kind=url")
      |> fill_in("Add", with: "https://spam.example/buy")
      |> click_button("Screen it")
      |> assert_has("#screened td", text: "spam.example")
      |> click_button("#screened button", "Remove")
      |> refute_has("#screened td", text: "spam.example")

      assert Screening.list("url") == []
      assert ["screening.create", "screening.delete"] = actions()
    end
  end

  describe "post authors" do
    test "staff give posts another author from the thread tools", ctx do
      %{conn: conn, admin: admin, member: member} = ctx
      category = category_fixture()
      thread = thread_fixture(category, admin, %{title: "Imported"})
      [post] = thread.posts

      conn
      |> log_in_as(admin)
      |> visit(~p"/categories/#{category.id}/threads/#{thread.id}/tools")
      |> within("#owner-form", fn session ->
        session
        |> check("#owner-post-#{post.id}", "@boss", exact: false)
        |> fill_in("New author's username", with: "@member")
        |> click_button("Change author")
      end)
      |> assert_has("#flash-info", text: "1 posts now by @member.")

      assert Repo.get!(Firefly.Discussion.Post, post.id).user_id == member.id

      assert %{details: %{"from" => ["boss"], "to" => "member"}} =
               Repo.get_by!(StaffAction, action: "post.change_owner")
    end
  end

  describe "groups" do
    test "are renamed and deleted, except the staff groups", %{conn: conn, admin: admin} do
      {:ok, group} = Groups.create_group(%{"name" => "betas"}, admin)
      Groups.staff_group("moderator")

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/groups")
      |> refute_has("#rename-#{Groups.get_by_name("moderator").id}")
      |> within("#rename-#{group.id}", fn session ->
        session
        |> fill_in("New name for betas", with: "testers")
        |> click_button("Rename")
      end)
      |> assert_has("#flash-info", text: "Renamed betas to testers.")
      |> click_button("#group-#{group.id} button", "Delete")
      |> assert_has("#flash-info", text: "Deleted testers.")

      refute Groups.get_by_name("testers")
    end
  end
end
