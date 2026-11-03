defmodule Firefly.AdminPanelTest do
  use Firefly.DataCase
  # Approvals notify, password resets and test emails are emailed.
  use Bamboo.Test, shared: true

  import Firefly.Fixtures

  alias Firefly.{Accounts, Discussion, Groups, SiteSettings}
  alias Firefly.Accounts.{User, UserAdmin, UserIPs}
  alias Firefly.Discussion.{Category, Post}
  alias Firefly.Moderation.{Akismet, Posting, Screening, StaffAction}
  alias Firefly.Notifications.{EmailLog, Subscriptions}

  setup do
    on_exit(&SiteSettings.clear_cache/0)
    %{admin: admin_fixture(%{username: "boss"}), category: category_fixture("General")}
  end

  defp actions, do: Repo.all(from(a in StaffAction, order_by: a.id, select: a.action))

  defp moderator do
    user = user_fixture()
    {:ok, _} = Groups.add_role(user, Groups.staff_group("moderator"))
    user
  end

  defp register(username) do
    Accounts.register_user(%{
      username: username,
      email: "#{username}@example.com",
      password: "s3cret-password"
    })
  end

  describe "moderators" do
    test "are staff who moderate but don't run the site", %{admin: admin} do
      mod = moderator()
      member = user_fixture()

      assert Accounts.moderator?(mod) and Accounts.staff?(mod)
      refute Accounts.admin?(mod)

      for action <- [:review, :view_users, :approve_user, :view_staff_log, :manage_screening],
          do: assert(Bodyguard.permit?(Discussion, action, mod, %{}), "#{action}")

      for action <- [:manage_site_settings, :manage_users, :manage_category, :manage_emails],
          do: refute(Bodyguard.permit?(Discussion, action, mod, %{}), "#{action}")

      assert Bodyguard.permit?(Discussion, :penalize_user, mod, member)
      # Staff can't be penalized, by anyone.
      refute Bodyguard.permit?(Discussion, :penalize_user, admin, mod)
      refute Bodyguard.permit?(Discussion, :penalize_user, mod, admin)
    end

    test "the moderator group stays closed and staff-only like admin's" do
      role = Groups.staff_group("moderator")

      assert {:error, changeset} =
               Groups.update_settings(role, %{"membership" => "open"}, admin_fixture())

      assert "must be closed for a staff group" in errors_on(changeset).membership
      assert {:error, :closed} = Groups.join(role, user_fixture())
    end
  end

  describe "impersonation policy" do
    test "admins impersonate members, never staff, themselves or suspended accounts", %{
      admin: admin
    } do
      member = user_fixture()
      refute Bodyguard.permit?(Discussion, :impersonate, admin, admin)
      refute Bodyguard.permit?(Discussion, :impersonate, admin, admin_fixture())
      refute Bodyguard.permit?(Discussion, :impersonate, admin, moderator())
      refute Bodyguard.permit?(Discussion, :impersonate, moderator(), member)
      assert Bodyguard.permit?(Discussion, :impersonate, admin, member)

      suspended = Repo.update!(change(member, suspended_until: ~U[9999-01-01 00:00:00Z]))
      refute Bodyguard.permit?(Discussion, :impersonate, admin, suspended)
    end
  end

  describe "approving new accounts" do
    test "with must_approve_users on, new accounts can read but not post until approved", ctx do
      %{admin: admin, category: category} = ctx
      {:ok, _} = SiteSettings.update(%{"must_approve_users" => "true"}, admin)

      {:ok, ada} = register("ada")
      {:ok, ada} = Accounts.confirm_user(ada)
      assert User.pending_approval?(ada)
      assert Posting.check(ada) == {:error, :pending_approval}
      assert UserAdmin.pending_count() == 1
      assert [%{id: id}] = UserAdmin.list(%{"filter" => "pending"}, 1).entries
      assert id == ada.id

      {:ok, ada} = UserAdmin.approve(ada, admin)
      refute User.pending_approval?(ada)
      assert Posting.check(ada) == :ok
      assert {:ok, _} = Discussion.create_thread(category, ada, %{title: "Hi all", body: "Hello"})
      assert [%{kind: "approved"}] = Firefly.Notifications.notifications_for(ada)
      assert {:error, :not_pending} = UserAdmin.approve(ada, admin)
      assert "user.approve" in actions()
    end

    test "invited people and accounts made while it's off are approved", %{admin: admin} do
      {:ok, before} = register("early")
      refute User.pending_approval?(before)

      {:ok, _} = SiteSettings.update(%{"must_approve_users" => "true"}, admin)

      {:ok, invited} =
        Accounts.register_invited_user(
          %{username: "guest", email: "guest@example.com", password: "s3cret-password"},
          true
        )

      refute User.pending_approval?(invited)
    end

    test "rejecting deletes the account", %{admin: admin} do
      {:ok, _} = SiteSettings.update(%{"must_approve_users" => "true"}, admin)
      {:ok, spammer} = register("spammer")

      {:ok, rejected} = UserAdmin.reject(spammer, admin)
      assert User.deleted?(rejected)
      assert rejected.username == User.deleted_username(spammer.id)
      assert "user.reject" in actions()
    end
  end

  describe "editing, anonymizing, deleting" do
    test "edits are logged with before and after", %{admin: admin} do
      member = user_fixture(%{username: "old_name"})
      {:ok, member} = UserAdmin.update(member, %{"username" => "new_name"}, admin)
      assert member.username == "new_name"

      assert [%{action: "user.edit", details: %{"username" => change}}] = Repo.all(StaffAction)
      assert change == %{"before" => "old_name", "after" => "new_name"}

      assert {:error, changeset} = UserAdmin.update(member, %{"email" => "nope"}, admin)
      assert "must be a valid email" in errors_on(changeset).email
    end

    test "anonymizing keeps posts; deleting removes them; staff are safe", ctx do
      %{admin: admin, category: category} = ctx
      writer = user_fixture()
      thread = thread_fixture(category, writer)
      other_thread = thread_fixture(category, admin)
      {:ok, reply} = Discussion.create_post(other_thread, writer, %{body: "A reply"})

      assert {:error, :staff} = UserAdmin.anonymize(admin_fixture(), admin)
      assert {:error, :staff} = UserAdmin.delete(moderator(), admin)

      {:ok, deleted} = UserAdmin.delete(writer, admin)
      assert User.deleted?(deleted)
      refute Repo.get(Discussion.Thread, thread.id)
      assert Post.deleted?(Repo.get!(Post, reply.id))
      assert Repo.get(Discussion.Thread, other_thread.id)

      assert %{action: "user.delete", details: %{"threads" => 1, "posts" => 1}} =
               Repo.get_by!(StaffAction, action: "user.delete")

      keeper = user_fixture()
      {:ok, kept} = Discussion.create_post(other_thread, keeper, %{body: "Kept"})
      {:ok, _} = UserAdmin.anonymize(keeper, admin)
      refute Post.deleted?(Repo.get!(Post, kept.id))
    end
  end

  describe "merging" do
    test "moves what the source owns into the target and removes the source", ctx do
      %{admin: admin, category: category} = ctx
      source = user_fixture(%{username: "dupe"})
      target = user_fixture(%{username: "main"})
      group = elem(Groups.create_group(%{"name" => "beta"}, admin), 1)
      {:ok, _} = Groups.add_role(source, group)
      {:ok, _} = Groups.add_role(target, group)

      thread = thread_fixture(category, admin)
      {:ok, post} = Discussion.create_post(thread, source, %{body: "From the dupe"})
      {:ok, liked} = Discussion.create_post(thread, admin, %{body: "Likeable"})
      :ok = Discussion.like_post(liked, source)
      :ok = Discussion.like_post(liked, target)

      assert {:error, :same_user} = UserAdmin.merge(target, target, admin)
      assert {:error, :staff} = UserAdmin.merge(admin_fixture(), target, admin)

      {:ok, _} = UserAdmin.merge(source, target, admin)

      refute Repo.get(User, source.id)
      assert Repo.get!(Post, post.id).user_id == target.id
      assert Groups.member?(group, target)

      likes =
        Repo.all(from(l in "forums_post_likes", where: l.post_id == ^liked.id, select: l.user_id))

      assert likes == [target.id]

      assert %{details: %{"from" => "dupe", "to" => "main"}} =
               Repo.get_by!(StaffAction, action: "user.merge")
    end
  end

  describe "roles, resets and notices" do
    test "granting and revoking staff roles", %{admin: admin} do
      member = user_fixture()
      {:ok, _} = UserAdmin.set_staff_role(member, "moderator", true, admin)
      assert Accounts.moderator?(member)
      {:ok, _} = UserAdmin.set_staff_role(member, "moderator", false, admin)
      refute Accounts.moderator?(member)
      assert {:error, :own_admin} = UserAdmin.set_staff_role(admin, "admin", false, admin)
      assert ["role.grant", "role.revoke"] = actions()
    end

    test "password reset links and notices", %{admin: admin} do
      member = user_fixture()
      assert :ok = UserAdmin.send_password_reset(member, admin)
      assert_email_delivered_with(to: [nil: member.email], subject: "Reset your Firefly password")

      assert {:error, :blank_subject} =
               UserAdmin.send_notification(member, %{"subject" => " "}, admin)

      {:ok, notice} = UserAdmin.send_notification(member, %{"subject" => "Welcome!"}, admin)
      assert [%{kind: "staff", subject: "Welcome!"}] = UserAdmin.notifications(member)
      {:ok, _} = UserAdmin.delete_notification(member, notice.id, admin)
      assert UserAdmin.notifications(member) == []

      assert ["user.password_reset", "notification.send", "notification.delete"] = actions()
    end
  end

  describe "IP addresses" do
    test "are recorded, listed, shared and searchable" do
      ada = user_fixture()
      bob = user_fixture()
      :ok = UserIPs.record(ada, {203, 0, 113, 5})
      :ok = UserIPs.record(ada, "203.0.113.5")
      :ok = UserIPs.record(bob, "203.0.113.5")

      assert [%{ip: "203.0.113.5"}] = UserIPs.for_user(ada)
      assert [%{id: id}] = UserIPs.sharing(ada)
      assert id == bob.id

      ids = UserAdmin.list(%{"q" => "203.0.113.5"}, 1).entries |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([ada.id, bob.id])
    end
  end

  describe "screening" do
    setup do
      on_exit(fn -> Akismet.put_client(%{}) end)
      :ok
    end

    test "blocks sign-ups from screened emails and IPs, and logs each block", %{admin: admin} do
      {:ok, item} = Screening.create(%{"kind" => "email", "value" => "*@Spam.Example"}, admin)
      assert item.value == "*@spam.example"

      assert {:error, changeset} = register_with("bot", "bot@spam.example")
      assert "can't be used to sign up here" in errors_on(changeset).email

      {:ok, _} = Screening.create(%{"kind" => "ip", "value" => "198.51.100.0/24"}, admin)
      Akismet.put_client(%{ip: "198.51.100.7"})
      assert {:error, changeset} = register_with("bot2", "bot2@fine.example")
      assert errors_on(changeset).email != []

      Akismet.put_client(%{ip: "192.0.2.1"})
      assert {:ok, _} = register_with("human", "human@fine.example")

      assert [%{match_count: 1}] = Screening.list("email")
      blocks = Repo.all(from(a in StaffAction, where: a.action == "screening.block"))
      assert length(blocks) == 2
      assert Enum.all?(blocks, &is_nil(&1.actor_id))
    end

    test "blocks posts linking screened domains, except staff's", ctx do
      %{admin: admin, category: category} = ctx

      {:ok, _} =
        Screening.create(%{"kind" => "url", "value" => "https://www.spam.example/x"}, admin)

      assert [%{value: "spam.example"}] = Screening.list("url")
      member = user_fixture()

      assert {:error, changeset} =
               Discussion.create_thread(category, member, %{
                 title: "Deals",
                 body: "See https://shop.spam.example/now"
               })

      assert errors_on(changeset) |> inspect() =~ "links a site that's blocked here"

      assert {:ok, _} =
               Discussion.create_thread(category, admin, %{
                 title: "Warning",
                 body: "Don't visit https://spam.example"
               })
    end

    test "validates entries and logs changes", %{admin: admin} do
      assert {:error, changeset} =
               Screening.create(%{"kind" => "ip", "value" => "not an ip"}, admin)

      assert errors_on(changeset).value != []
      {:ok, item} = Screening.create(%{"kind" => "ip", "value" => "10.0.0.1"}, admin)
      assert {:error, _} = Screening.create(%{"kind" => "ip", "value" => "10.0.0.1"}, admin)
      {:ok, _} = Screening.delete(item.id, admin)
      assert ["screening.create", "screening.delete"] = actions()
    end

    defp register_with(username, email),
      do: Accounts.register_user(%{username: username, email: email, password: "s3cret-password"})
  end

  describe "category permissions" do
    test "groups can be given full, reply or read-only access", ctx do
      %{admin: admin, category: category} = ctx
      readers = elem(Groups.create_group(%{"name" => "readers"}, admin), 1)
      writers = elem(Groups.create_group(%{"name" => "writers"}, admin), 1)
      reader = user_fixture()
      writer = user_fixture()
      {:ok, _} = Groups.add_role(reader, readers)
      {:ok, _} = Groups.add_role(writer, writers)
      thread = thread_fixture(category, admin)

      {:ok, _} =
        Discussion.set_category_permissions(
          category,
          %{to_string(readers.id) => "readonly", to_string(writers.id) => "create_post"},
          admin
        )

      assert Bodyguard.permit?(Discussion, :view_category, reader, category)
      refute Bodyguard.permit?(Discussion, :view_category, user_fixture(), category)
      assert Posting.check(reader, thread) == {:error, :read_only_category}
      assert Posting.check(writer, thread) == :ok

      assert {:error, changeset} =
               Discussion.create_thread(category, writer, %{title: "New one", body: "Hello"})

      assert "can't be started in this category" in errors_on(changeset).title

      assert %{action: "category.permissions", details: %{"permissions" => %{"after" => after_}}} =
               Repo.get_by!(StaffAction, action: "category.permissions")

      assert after_ == %{"readers" => "readonly", "writers" => "create_post"}

      {:ok, _} = Discussion.set_category_permissions(category, %{}, admin)
      assert Posting.check(reader, thread) == :ok
    end

    test "moving categories renumbers their siblings", %{admin: admin} do
      category_fixture("B")
      c = category_fixture("C")
      {:ok, _} = Discussion.move_category(c, :up, admin)

      titles =
        Repo.all(
          from(cat in Category,
            where: is_nil(cat.parent_id),
            order_by: [cat.position, cat.title],
            select: cat.title
          )
        )

      assert titles == ["C", "B", "General"]
      assert "category.update" in actions()
    end

    test "new members start at a category's default level", %{admin: admin, category: category} do
      existing = user_fixture()

      {:ok, category} =
        Discussion.update_category(category, %{"default_notification_level" => "watching"}, admin)

      {:ok, newcomer} = register("newcomer")
      assert Subscriptions.category_level(newcomer, category) == "watching"
      assert Subscriptions.category_level(existing, category) == nil

      {:ok, count} = Discussion.apply_category_default(category, admin)
      assert count >= 1
      assert Subscriptions.category_level(existing, category) == "watching"
      assert "category.defaults" in actions()
    end
  end

  describe "the email log" do
    test "records sent and failed emails, prunes old ones, and sends tests", %{admin: admin} do
      assert :ok = EmailLog.send_test("ops@example.com", admin)
      assert {:error, :invalid_address} = EmailLog.send_test("nope", admin)

      assert [%{to: "ops@example.com", template: "test_email", status: "sent"}] =
               EmailLog.list(%{}, 1).entries

      assert EmailLog.last_day_counts()["sent"] == 1
      assert "email.test" in actions()

      old = DateTime.add(DateTime.utc_now(:second), -40, :day)
      Repo.update_all(EmailLog, set: [inserted_at: old])
      assert EmailLog.run_due() == 1
      assert EmailLog.list(%{}, 1).entries == []
    end

    test "every template previews with sample data" do
      previews = Firefly.Notifications.Emails.previews()
      assert length(previews) >= 12

      for {template, email} <- previews do
        assert email.private.template == template
        assert email.subject != "" and email.html_body =~ "<"
      end
    end
  end
end
