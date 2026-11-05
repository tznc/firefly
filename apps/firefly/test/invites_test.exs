defmodule Firefly.InvitesTest do
  use Firefly.DataCase
  import Swoosh.TestAssertions

  # Mail is sent from other processes (the notifications process, LiveViews).
  setup :set_swoosh_global

  alias Firefly.{Accounts, Groups, Notifications, SiteSettings}
  alias Firefly.Accounts.{Auth, Invite, Invites, User}

  import Firefly.Fixtures

  setup do
    %{admin: admin_fixture(), member: user_fixture(%{trust_level: 2})}
  end

  defp register(invite, username, email \\ nil) do
    Invites.register(invite, %{
      "username" => username,
      "email" => email || "#{username}@example.com",
      "password" => "a long enough password"
    })
  end

  test "members at min_trust_to_invite and admins may invite", %{admin: admin, member: member} do
    assert Invites.may_invite?(member)
    assert Invites.may_invite?(admin)
    refute Invites.may_invite?(user_fixture(%{trust_level: 1}))
    assert {:error, :not_allowed} = Invites.create(user_fixture(%{trust_level: 1}), %{})

    SiteSettings.update(%{"min_trust_to_invite" => "3"}, admin)
    refute Invites.may_invite?(member)
  end

  test "an email invite is emailed and makes a confirmed account with that address", ctx do
    {:ok, invite} = Invites.create(ctx.member, %{"email" => "New@Example.com"})
    assert invite.email == "new@example.com"
    assert invite.emailed_at
    assert_received {:email, %{to: [{"", "new@example.com"}], text_body: text}}
    assert text =~ "/invites/#{invite.key}"

    {:ok, user} = register(invite, "newbie", "other@example.com")
    assert user.email == "new@example.com"
    assert User.confirmed?(user)

    invite = Invites.get_by_key(invite.key)
    assert invite.uses == 1
    assert Invite.problem(invite) == :used_up
    assert [%{user_id: id}] = invite.redemptions
    assert id == user.id

    assert [%{kind: "invite_redeemed", subject: "@newbie accepted your invitation"}] =
             Notifications.notifications_for(ctx.member)

    assert {:error, :used_up} = register(invite, "another")
  end

  test "an email invite can't go to an existing account", ctx do
    assert {:error, changeset} = Invites.create(ctx.member, %{"email" => ctx.admin.email})
    assert errors_on(changeset).email == ["already has an account"]
  end

  test "a link takes up to max_uses people, at its domain", ctx do
    {:ok, invite} =
      Invites.create(ctx.member, %{"max_uses" => "2", "domain" => "@Corp.example"})

    assert {:error, :wrong_domain} = register(invite, "outsider", "x@elsewhere.com")
    assert {:ok, _} = register(invite, "one", "one@corp.example")
    assert {:ok, user} = register(invite, "two", "two@corp.example")
    refute User.confirmed?(user)
    assert {:error, :used_up} = register(invite, "three", "three@corp.example")
  end

  test "revoked and expired invites can't be used", ctx do
    {:ok, invite} = Invites.create(ctx.member, %{"max_uses" => "5"})
    assert {:error, :not_allowed} = Invites.revoke(invite, user_fixture(%{trust_level: 2}))
    {:ok, revoked} = Invites.revoke(invite, ctx.admin)
    assert {:error, :revoked} = register(revoked, "late")

    {:ok, invite} = Invites.create(ctx.member, %{"max_uses" => "5"})
    invite = Repo.update!(change(invite, expires_at: ~U[2020-01-01 00:00:00Z]))
    assert {:error, :expired} = register(invite, "later")
  end

  test "staff invites add a group and land on a thread", ctx do
    {:ok, group} = Groups.create_role("insiders")
    thread = thread_fixture(category_fixture(), ctx.admin)

    {:ok, invite} =
      Invites.create(ctx.admin, %{
        "max_uses" => "3",
        "role_id" => to_string(group.id),
        "thread" => "https://forum.example/categories/1/threads/#{thread.id}"
      })

    assert invite.role_id == group.id
    assert Invites.destination(invite) =~ "/threads/#{thread.id}"

    # Members already signed in redeem it to join the group.
    member = user_fixture()
    assert {:ok, _} = Invites.redeem(invite, member)
    assert {:error, :already_redeemed} = Invites.redeem(invite, member)
    assert Repo.exists?(where(Groups.RoleMembership, user_id: ^member.id, role_id: ^group.id))

    # Members can't set either.
    {:ok, plain} =
      Invites.create(ctx.member, %{"max_uses" => "1", "role_id" => to_string(group.id)})

    assert plain.role_id == nil
  end

  test "invite_only closes registration but not invites, social logins included", ctx do
    SiteSettings.update(%{"invite_only" => "true"}, ctx.admin)
    refute Accounts.registration_open?()

    assert {:error, :registration_closed} =
             Accounts.register_user(%{
               "username" => "walkin",
               "email" => "walkin@example.com",
               "password" => "a long enough password"
             })

    info = %{provider: "google", uid: "g-1", nickname: "guest", email: "guest@example.com"}
    assert {:error, "New registrations are closed."} = Auth.login(info)

    {:ok, invite} = Invites.create(ctx.member, %{"email" => "guest@example.com"})
    assert {:ok, user} = Auth.login(info, invite)
    assert User.confirmed?(user)
    assert Invites.get_by_key(invite.key).uses == 1

    {:ok, other} = Invites.create(ctx.member, %{"email" => "someone@example.com"})
    info = %{provider: "google", uid: "g-2", nickname: "who", email: "who@example.com"}
    assert {:error, "This invitation is for another email address."} = Auth.login(info, other)
    refute Accounts.get_user_by_email("who@example.com")

    assert {:ok, _} = register(Invites.get_by_key(other.key), "someone")

    SiteSettings.update(%{"allow_registrations" => "false"}, ctx.admin)
    {:ok, link} = Invites.create(ctx.member, %{"max_uses" => "5"})
    assert {:error, :registration_closed} = register(link, "nobody")
  end

  test "resending an email invite starts its time over", ctx do
    {:ok, invite} = Invites.create(ctx.member, %{"email" => "late@example.com"})
    invite = Repo.update!(change(invite, expires_at: ~U[2020-01-01 00:00:00Z]))

    assert {:ok, resent} = Invites.resend(invite, ctx.member)
    assert Invite.problem(resent) == nil

    {:ok, link} = Invites.create(ctx.member, %{"max_uses" => "2"})
    assert {:error, :not_email} = Invites.resend(link, ctx.member)
  end
end
