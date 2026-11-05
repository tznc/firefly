defmodule FireflyWeb.InvitesTest do
  use FireflyWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  # Mail is sent from other processes (the notifications process, LiveViews).
  setup :set_swoosh_global

  alias Firefly.{Accounts, Groups, Repo, SiteSettings}
  alias Firefly.Accounts.{Invites, User}

  setup do
    {:ok, admin: admin_fixture(), member: user_fixture(%{trust_level: 2})}
  end

  test "members invite by email and see it redeemed", %{conn: conn, member: member} do
    session =
      conn
      |> log_in_as(member)
      |> visit(~p"/invites")
      |> assert_has("#invites-empty")
      |> fill_in("Email", with: "friend@example.com")
      |> click_button("Send invitation")
      |> assert_has("#flash-info", text: "Invitation sent to friend@example.com.")
      |> assert_has("#invites li", text: "friend@example.com")

    [invite] = Invites.list_for(member)

    {:ok, friend} =
      Invites.register(invite, %{"username" => "friend", "password" => "a long enough password"})

    session
    |> visit(~p"/invites")
    |> assert_has("#invite-#{invite.id}", text: "Redeemed")
    |> assert_has("#invite-#{invite.id} a", text: "@#{friend.username}")
  end

  test "links can be made and revoked", %{conn: conn, member: member} do
    conn
    |> log_in_as(member)
    |> visit(~p"/invites")
    |> click_button("Invite link")
    |> fill_in("Uses", with: "3")
    |> click_button("Create link")
    |> assert_has("#flash-info", text: "Invite link created.")
    |> assert_has("#invites code", text: "/invites/")
    |> click_button("Revoke")
    |> assert_has("#flash-info", text: "Invitation revoked.")
    |> assert_has("#invites .badge", text: "Revoked")
  end

  test "members below the trust level can't invite", %{conn: conn} do
    conn
    |> log_in_as(user_fixture(%{trust_level: 1}))
    |> visit(~p"/invites")
    |> assert_has("#cannot-invite")
    |> refute_has("#invite-form")
  end

  test "an invite signs a visitor up on an invite-only site, landing on its thread", ctx do
    SiteSettings.update(%{"invite_only" => "true"}, ctx.admin)
    category = category_fixture()
    thread = thread_fixture(category, ctx.admin)

    {:ok, invite} =
      Invites.create(ctx.admin, %{"max_uses" => "5", "thread" => to_string(thread.id)})

    ctx.conn
    |> visit(~p"/login")
    |> refute_has("a", text: "Create Account")

    ctx.conn
    |> visit(~p"/invites/#{invite.key}")
    |> assert_has("h1", text: "Join")
    |> fill_in("Username", with: "invitee")
    |> fill_in("Email", with: "invitee@example.com")
    |> fill_in("Password", with: "a long enough password")
    |> click_button("Create account")
    |> assert_path(~p"/categories/#{category}/threads/#{thread}")
    |> assert_has("#flash-info", text: "Successfully authenticated.")

    assert %User{} = Accounts.get_user_by_username("invitee")
  end

  test "signed-in members accept a link to join its group", %{conn: conn, admin: admin} do
    {:ok, group} = Groups.create_role("crew")
    {:ok, invite} = Invites.create(admin, %{"max_uses" => "5", "role_id" => to_string(group.id)})
    member = user_fixture()

    conn
    |> log_in_as(member)
    |> visit(~p"/invites/#{invite.key}")
    |> click_button("Accept invitation")
    |> assert_has("#flash-info", text: "Invitation accepted.")

    assert Repo.get_by(Groups.RoleMembership, user_id: member.id, role_id: group.id)
  end

  test "a used-up invite says so", %{conn: conn, admin: admin} do
    {:ok, invite} = Invites.create(admin, %{"max_uses" => "1"})
    {:ok, _} = Invites.revoke(invite, admin)

    conn
    |> visit(~p"/invites/#{invite.key}")
    |> assert_has("#invite-problem", text: "This invitation was revoked.")
    |> refute_has("#invite-registration-form")
  end

  test "staff see everyone's invites", %{conn: conn, admin: admin, member: member} do
    {:ok, _} = Invites.create(member, %{"email" => "pal@example.com"})

    conn
    |> log_in_as(admin)
    |> visit(~p"/invites")
    |> click_link("All invites")
    |> assert_has("#invites li", text: "by @#{member.username}")
  end
end
