defmodule FireflyWeb.GroupsTest do
  use FireflyWeb.ConnCase
  use Bamboo.Test, shared: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest, only: [live: 2, render_click: 3]
  require Phoenix.LiveViewTest

  alias Firefly.{Discussion, Groups, Messaging, Notifications, Repo}
  alias Firefly.Discussion.Mentions
  alias Firefly.Rendering.Markdown
  alias Firefly.Groups.Role
  alias Firefly.Messaging.Conversation
  alias Firefly.Moderation.StaffAction

  setup do
    admin = admin_fixture(%{username: "boss"})
    {:ok, team} = Groups.create_group(%{name: "team"}, admin)
    owner = user_fixture(%{username: "olivia"})
    member = user_fixture(%{username: "mia"})
    outsider = user_fixture(%{username: "otto"})
    {:ok, _} = Groups.add_member(team, "olivia", admin)
    {:ok, _} = Groups.add_member(team, "mia", admin)
    {:ok, _} = Groups.set_owner(team, owner, true, admin)
    %{admin: admin, team: team, owner: owner, member: member, outsider: outsider}
  end

  defp settings(group, attrs, admin) do
    {:ok, group} = Groups.update_settings(group, attrs, admin)
    group
  end

  defp kinds(user, kind),
    do: Enum.filter(Notifications.notifications_for(user), &(&1.kind == kind))

  defp flush, do: :sys.get_state(Notifications)

  describe "visibility" do
    test "public groups for everyone, members groups for members, staff groups for staff", ctx do
      %{conn: conn, team: team, admin: admin, member: member, outsider: outsider} = ctx

      # Existing groups start staff-only.
      conn |> visit(~p"/groups") |> refute_has("#groups", text: "team")
      conn |> visit(~p"/groups/team") |> assert_path(~p"/groups")
      conn |> log_in_as(admin) |> visit(~p"/groups") |> assert_has("#groups", text: "team")

      team = settings(team, %{"visibility" => "members"}, admin)
      conn |> log_in_as(member) |> visit(~p"/groups/team") |> assert_has("h1", text: "team")

      conn
      |> log_in_as(outsider)
      |> visit(~p"/groups/team")
      |> assert_has("#flash-error", text: "No such group.")

      settings(team, %{"visibility" => "public", "description" => "The core team."}, admin)

      conn
      |> visit(~p"/groups")
      |> assert_has("#groups", text: "2 members")
      |> click_link("team")
      |> assert_has("#group-about", text: "The core team.")
      |> click_link("Members")
      |> assert_has("#group-members", text: "@olivia")
      |> assert_has("#member-#{ctx.owner.id}", text: "Owner")
    end

    test "settings changes are staff-logged; the admin group stays closed", %{
      team: team,
      admin: admin
    } do
      settings(team, %{"membership" => "open"}, admin)
      assert Repo.get_by(StaffAction, action: "role.update")

      admin_group = Repo.get_by!(Role, name: "admin")

      assert {:error, changeset} =
               Groups.update_settings(admin_group, %{"membership" => "open"}, admin)

      assert changeset.errors[:membership]
      assert {:error, :closed} = Groups.join(admin_group, user_fixture())
    end

    test "admins change settings on the staff page", %{conn: conn, admin: admin, team: team} do
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/groups")
      |> within("#group-settings-#{team.id}", fn session ->
        session
        |> select("Joining", option: "Anyone can join")
        |> select("Who sees it", option: "Everyone")
        |> click_button("Save settings")
      end)
      |> assert_has("#flash-info", text: "Saved team's settings.")

      assert %{membership: "open", visibility: "public"} = Groups.get_group!(team.id)
    end
  end

  describe "joining" do
    setup %{team: team, admin: admin} do
      %{team: settings(team, %{"visibility" => "public"}, admin)}
    end

    test "open groups: anyone joins and leaves", %{
      conn: conn,
      team: team,
      admin: admin,
      outsider: outsider
    } do
      settings(team, %{"membership" => "open"}, admin)

      conn
      |> log_in_as(outsider)
      |> visit(~p"/groups/team")
      |> click_button("Join")
      |> assert_has("#flash-info", text: "You joined team.")
      |> click_button("Leave")
      |> assert_has("#flash-info", text: "You left team.")

      refute Groups.member?(team, outsider)
    end

    test "closed groups can't be joined", %{team: team, outsider: outsider} do
      assert {:error, :closed} = Groups.join(team, outsider)
    end

    test "requests notify the owners, who approve or deny", ctx do
      %{conn: conn, team: team, admin: admin, owner: owner, outsider: outsider} = ctx
      team = settings(team, %{"membership" => "request"}, admin)

      conn
      |> log_in_as(outsider)
      |> visit(~p"/groups/team")
      |> fill_in("Why you'd like to join (optional)", with: "I fix bugs")
      |> click_button("Ask to join")
      |> assert_has("#flash-info", text: "You asked to join team.")
      |> assert_has(".badge", text: "Request sent")

      assert [%{subject: "@otto asked to join team", body: "I fix bugs"}] =
               kinds(owner, "group_request")

      assert kinds(admin, "group_request") == []
      assert {:error, :already_requested} = Groups.join(team, outsider)

      conn
      |> log_in_as(owner)
      |> visit(~p"/groups/team/requests")
      |> assert_has("#group-requests", text: "I fix bugs")
      |> click_button("Approve")
      |> assert_has("#flash-info", text: "Added @otto.")

      assert Groups.member?(team, outsider)
      assert [%{subject: "You joined team"}] = kinds(outsider, "group_request")
      assert Repo.get_by(StaffAction, action: "role.grant", actor_id: owner.id)

      # Denied, with no owners: the admins decide.
      newbie = user_fixture()
      {:ok, _} = Groups.set_owner(team, owner, false, admin)
      {:ok, :requested} = Groups.join(team, newbie)
      assert [_] = kinds(admin, "group_request")
      [request] = Groups.pending(team)
      {:ok, _} = Groups.decide(team, request.id, false, admin)
      refute Groups.member?(team, newbie)

      assert [%{subject: "Your request to join team was declined"}] =
               kinds(newbie, "group_request")
    end

    test "owners invite; the invitee accepts", %{
      conn: conn,
      team: team,
      owner: owner,
      outsider: outsider
    } do
      conn
      |> log_in_as(owner)
      |> visit(~p"/groups/team/members")
      |> fill_in("Invite someone", with: "otto")
      |> click_button("Invite")
      |> assert_has("#flash-info", text: "Invited @otto.")

      assert [%{subject: "@olivia invited you to join team"}] = kinds(outsider, "group_invite")

      conn
      |> log_in_as(outsider)
      |> visit(~p"/groups/team")
      |> assert_has("#invitation", text: "You're invited")
      |> click_button("Accept")
      |> assert_has("#flash-info", text: "You joined team.")

      assert Groups.member?(team, outsider)
    end
  end

  describe "owners" do
    test "manage members; other members can't", ctx do
      %{conn: conn, team: team, owner: owner, member: member, outsider: outsider} = ctx

      assert {:error, :unauthorized} = Groups.add_member(team, "otto", member)
      assert {:error, :unauthorized} = Groups.remove_member(team, owner, member)
      settings(team, %{"visibility" => "members"}, ctx.admin)

      conn
      |> log_in_as(owner)
      |> visit(~p"/groups/team/members")
      |> fill_in("Add a member", with: "otto")
      |> click_button("Add member")
      |> assert_has("#flash-info", text: "Added @otto.")
      |> click_button("Remove otto")
      |> assert_has("#flash-info", text: "Removed @otto.")

      refute Groups.member?(team, outsider)
      assert Repo.get_by(StaffAction, action: "role.revoke", actor_id: owner.id)
    end

    test "admins make owners; only admins manage the admin group", ctx do
      %{conn: conn, team: team, admin: admin, member: member, owner: owner} = ctx
      {:ok, view, _html} = conn |> log_in_as(admin) |> live(~p"/groups/team/members")
      render_click(view, "set_owner", %{"user_id" => member.id, "owner" => "true"})
      assert Groups.owner?(team, member)
      assert Repo.get_by(StaffAction, action: "role.owner", target_id: member.id)

      # Only admins manage the admin group's members, whoever owns it.
      admin_group = Repo.get_by!(Role, name: "admin")
      refute Groups.manager?(admin_group, owner)
      assert {:error, :unauthorized} = Groups.add_member(admin_group, "mia", owner)
    end
  end

  describe "mentions" do
    setup %{team: team, admin: admin} do
      {:ok, _} = Notifications.start_link()
      category = category_fixture()
      thread = thread_fixture(category, user_fixture())
      flush()
      %{team: settings(team, %{"visibility" => "public"}, admin), thread: thread}
    end

    defp mention(thread, author, body \\ "Ping @team!") do
      {:ok, post} = Discussion.create_post(thread, author, %{body: body})
      flush()
      post
    end

    test "notify members when the author may mention the group", ctx do
      %{
        team: team,
        admin: admin,
        owner: owner,
        member: member,
        outsider: outsider,
        thread: thread
      } = ctx

      # Nobody (but staff) by default.
      mention(thread, member)
      assert kinds(owner, "group_mentioned") == []

      settings(team, %{"mentionable" => "members"}, admin)
      mention(thread, outsider)
      assert kinds(owner, "group_mentioned") == []

      post = mention(thread, member, "Hey @Team and @olivia")
      # Olivia was mentioned by name: one notification, not two.
      assert [%{post_id: id}] =
               Notifications.notifications_for(owner)
               |> Enum.filter(&(&1.kind in ~w(mentioned group_mentioned)))

      assert id == post.id
      assert kinds(member, "group_mentioned") == []

      post = mention(thread, admin, "@team again")
      assert [%{subject: subject} | _] = kinds(member, "group_mentioned")
      assert subject =~ "mentioned @team"

      # An edit doesn't notify again.
      {:ok, _} = Discussion.update_post(post, admin, %{body: "@team again, edited"})
      flush()
      assert length(kinds(member, "group_mentioned")) == 1
    end

    test "skip members who can't read the thread", ctx do
      %{team: team, admin: admin, member: member} = ctx
      settings(team, %{"mentionable" => "everyone"}, admin)
      {:ok, leads} = Groups.create_group(%{name: "leads"}, admin)
      secret = category_fixture("Secret")
      {:ok, _} = Discussion.update_category(secret, %{role_ids: [leads.id]})
      {:ok, _} = Groups.add_member(leads, "boss", admin)
      thread = thread_fixture(secret, admin)
      flush()

      mention(thread, admin)
      assert kinds(member, "group_mentioned") == []
    end

    test "render as links to visible groups", %{team: team, admin: admin} do
      html = Markdown.render("Ask @team or @nobody", Mentions.refs(["Ask @team or @nobody"]))
      assert html =~ ~s{href="http://localhost:4002/groups/team"}

      settings(team, %{"visibility" => "staff"}, admin)
      refute Markdown.render("Ask @team", Mentions.refs(["Ask @team"])) =~ "/groups/team"
    end
  end

  describe "inboxes" do
    setup %{team: team, admin: admin} do
      {:ok, _} = Notifications.start_link()
      %{team: settings(team, %{"visibility" => "public", "messageable" => "members"}, admin)}
    end

    defp message_group(sender, recipients \\ "@team") do
      result =
        Messaging.start_conversation(sender, %{
          "recipients" => recipients,
          "title" => "Help",
          "body" => "Please"
        })

      flush()
      result
    end

    test "only those the group allows may message it", %{outsider: outsider} do
      assert {:error, changeset} = message_group(outsider)
      assert {"you can't message @team", _} = changeset.errors[:recipients]
    end

    test "members read and reply; others are notified by their level", ctx do
      %{conn: conn, team: team, owner: owner, member: member, outsider: outsider} = ctx
      quiet = user_fixture(%{username: "quiet"})
      tracker = user_fixture(%{username: "tracker", email: "tracker@example.com"})

      for {user, level} <- [{quiet, "muted"}, {tracker, "tracking"}] do
        {:ok, _} = Groups.add_member(team, user.username, ctx.admin)
        :ok = Groups.set_notification_level(team, user, level)
      end

      {:ok, conversation} = message_group(member)
      assert %Conversation{role_id: role_id} = conversation
      assert role_id == team.id
      refute Messaging.participant?(conversation, owner)

      assert [%{subject: subject}] = kinds(owner, "group_message")
      assert subject =~ "@mia messaged @team"
      assert_delivered_email_matches(%{to: [{_, "user" <> _}]})
      assert [_] = kinds(tracker, "group_message")
      assert kinds(quiet, "group_message") == []

      conn
      |> log_in_as(owner)
      |> visit(~p"/groups/team/messages")
      |> assert_has("#group-inbox", text: "Help")
      |> click_link("Help")
      |> assert_has("#messages", text: "Please")

      {:ok, _} = Messaging.reply(conversation, owner, %{"body" => "On it"})
      flush()
      assert Messaging.participant?(conversation, owner)
      # Mia's a participant: a plain message notification.
      assert Enum.any?(Notifications.notifications_for(member), &(&1.kind == "message"))

      # Outsiders and former members can't read it.
      conn
      |> log_in_as(outsider)
      |> visit(~p"/messages/#{conversation.id}")
      |> refute_has("#messages", text: "Please")

      {:ok, _} = Groups.remove_member(team, tracker, tracker)
      refute Messaging.reader?(conversation, tracker)
    end

    test "members choose their level", %{conn: conn, team: team, member: member} do
      conn
      |> log_in_as(member)
      |> visit(~p"/groups/team/messages")
      |> select("Messages to this group", option: "Muted: nothing")
      |> assert_has("#flash-info", text: "Notification level saved.")

      assert Groups.notification_level(team, member) == "muted"
    end
  end

  test "the activity tab shows members' readable posts", %{
    conn: conn,
    team: team,
    admin: admin,
    member: member
  } do
    settings(team, %{"visibility" => "public"}, admin)
    thread_fixture(category_fixture(), member, %{title: "Mia's thread", body: "Hello"})

    conn
    |> visit(~p"/groups/team/activity")
    |> assert_has("#group-activity", text: "Mia's thread")
  end

  test "export and deletion", %{team: team, admin: admin, outsider: outsider, owner: owner} do
    team = settings(team, %{"membership" => "request", "visibility" => "public"}, admin)
    {:ok, :requested} = Groups.join(team, outsider)

    assert %{memberships: memberships, pending: [%{group: "team", kind: "request"}]} =
             Groups.export(outsider)

    assert Enum.map(memberships, & &1.group) == ~w(trust_level_0 trust_level_1)
    assert %{memberships: memberships} = Groups.export(owner)
    assert Enum.any?(memberships, &match?(%{group: "team", owner: true}, &1))

    {:ok, _} = Firefly.Accounts.AccountDeletion.delete_account(outsider, outsider.username)
    assert Repo.all(from(r in "group_requests", select: r.id)) == []
  end
end
