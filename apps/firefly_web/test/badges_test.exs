defmodule FireflyWeb.BadgesTest do
  use FireflyWeb.ConnCase

  import Ecto.Query, only: [where: 2, where: 3]
  import Firefly.DataCase, only: [errors_on: 1]

  alias Firefly.{Badges, Discussion, Groups, JobRuns, Repo, TrustLevels}
  alias Firefly.Accounts.{AccountDeletion, AccountExport}
  alias Firefly.Accounts.User
  alias Firefly.Badges.{Badge, UserBadge}
  alias Firefly.Moderation.StaffAction
  alias Firefly.Notifications.Notification

  setup do
    admin = admin_fixture()
    category = category_fixture("General")
    thread = thread_fixture(category, admin)
    %{admin: admin, category: category, thread: thread}
  end

  defp badge(name), do: Repo.get_by!(Badge, name: name)

  defp names(user) do
    user
    |> Badges.user_badges()
    |> Enum.map(fn {badge, _count, _at} -> badge.name end)
    |> Enum.sort()
  end

  defp notified(user, kind),
    do: Repo.all(where(Notification, user_id: ^user.id, kind: ^kind))

  describe "system badges" do
    test "are created and granted by the job, once each", ctx do
      author = user_fixture()
      liker = user_fixture()

      {:ok, reply} =
        Discussion.create_post(ctx.thread, author, %{body: "hello @#{liker.username}"})

      Discussion.like_post(reply, liker)

      Badges.grant_earned(nil)
      Badges.grant_earned(nil)

      assert names(author) == ["Basic User", "First Mention", "Welcome"]
      assert names(liker) == ["Basic User", "First Like"]

      assert Repo.get_by!(UserBadge, user_id: author.id, badge_id: badge("Welcome").id).post_id ==
               reply.id

      assert length(notified(author, "badge_granted")) == 3
    end

    test "quotes, links, edits and a filled-in profile", ctx do
      user = user_fixture()

      {:ok, _} =
        Discussion.create_post(ctx.thread, user, %{
          body: "> [@someone said:](/x)\n>\n> hi\n\nsee /categories/1/threads/2"
        })

      {:ok, post} = Discussion.create_post(ctx.thread, user, %{body: "draft"})
      {:ok, _} = Discussion.update_post(post, user, %{body: "final"})
      Repo.update!(Ecto.Changeset.change(user, bio: "Hi"))

      Badges.grant_earned([user.id])
      assert names(user) == ["Basic User", "Editor", "First Link", "First Quote"]
    end

    test "nice reply is granted per post at 10 likes", ctx do
      author = user_fixture()
      likers = for _ <- 1..10, do: user_fixture()

      for _ <- 1..2 do
        {:ok, reply} = Discussion.create_post(ctx.thread, author, %{body: "great"})
        for liker <- likers, do: Discussion.like_post(reply, liker)
      end

      Badges.grant_earned([author.id])

      assert [{%Badge{name: "Nice Reply"}, 2, _at}] =
               Enum.filter(Badges.user_badges(author), &(elem(&1, 0).name == "Nice Reply"))
    end

    test "trust level changes grant trust level badges at once", %{admin: admin} do
      user = user_fixture(%{trust_level: 0})
      {:ok, _} = TrustLevels.set_level(user, 3, false, admin)
      assert names(user) == ["Basic User", "Member", "Regular"]
    end

    test "disabled badges aren't granted or shown", %{admin: admin} do
      Badges.grant_earned(nil)

      {:ok, _} =
        Badges.update_badge(badge("Leader"), %{"enabled" => "false", "name" => "X"}, admin)

      assert badge("Leader").enabled == false

      user = user_fixture(%{trust_level: 4})
      Badges.grant_earned([user.id])
      refute "Leader" in names(user)
    end

    test "the job runs every 15 minutes across nodes" do
      assert Badges.run_due() == :ok
      refute JobRuns.claim("badges", 900)
    end
  end

  describe "custom badges" do
    test "admins create, grant, revoke and delete them, staff-logged", %{admin: admin} do
      member = user_fixture()

      {:ok, badge} =
        Badges.create_badge(
          %{"name" => "Helper", "description" => "Helped out", "icon" => "hero-gift"},
          admin
        )

      assert {:ok, _} = Badges.grant(badge, member, admin, "Thanks!")
      assert Badges.grant(badge, member, admin) == {:error, :already_granted}

      assert [%Notification{subject: "You earned the \"Helper\" badge"}] =
               notified(member, "badge_granted")

      grant = Repo.get_by!(UserBadge, user_id: member.id)
      assert grant.granted_by_id == admin.id and grant.reason == "Thanks!"
      assert {:ok, _} = Badges.revoke(grant.id, admin)
      refute Badges.holds?(member, badge)

      assert {:ok, _} = Badges.delete_badge(badge, admin)
      assert {:error, :system} = Badges.delete_badge(%Badge{system: true}, admin)

      actions =
        Repo.all(
          where(
            StaffAction,
            [a],
            a.action in ~w(badge.create badge.grant badge.revoke badge.delete)
          )
        )

      assert length(actions) == 4
    end

    test "icons come from a fixed list", %{admin: admin} do
      assert {:error, changeset} =
               Badges.create_badge(%{"name" => "X", "icon" => "hero-nope"}, admin)

      assert "is invalid" in errors_on(changeset).icon
    end

    test "titles: only badges that allow one, lost on revoke", %{admin: admin} do
      member = user_fixture()
      {:ok, plain} = Badges.create_badge(%{"name" => "Plain", "icon" => "hero-star"}, admin)

      {:ok, titled} =
        Badges.create_badge(
          %{"name" => "Sage", "icon" => "hero-star", "allow_title" => "true"},
          admin
        )

      {:ok, _} = Badges.grant(plain, member, admin)
      {:ok, grant} = Badges.grant(titled, member, admin)

      assert Badges.set_title(member, plain.id) == {:error, :not_allowed}
      {:ok, member} = Badges.set_title(member, titled.id)
      assert Badges.title(member) == "Sage"

      {:ok, _} = Badges.revoke(grant.id, admin)
      assert Badges.title(Repo.get!(User, member.id)) == nil
    end
  end

  describe "pages" do
    test "badges list, a badge's grantees, and the profile tab", %{conn: conn, admin: admin} do
      member = user_fixture()
      {:ok, badge} = Badges.create_badge(%{"name" => "Helper", "icon" => "hero-gift"}, admin)
      {:ok, _} = Badges.grant(badge, member, admin)

      conn
      |> log_in_as(member)
      |> visit(~p"/badges")
      |> assert_has("#badge-#{badge.id}", text: "Yours")
      |> click_link("#badge-#{badge.id} a", "Helper")
      |> assert_has("#grantees", text: "@#{member.username}")
      |> refute_has("#grant-form")
      |> visit(~p"/users/#{member}/badges")
      |> assert_has("#user-badges", text: "Helper")
    end

    test "a grant's post shows only to who may read it", %{conn: conn, admin: admin} do
      {:ok, role} = Groups.create_role("insiders")
      {:ok, secret} = Discussion.create_category(%{title: "Secret"})
      Repo.insert_all("forums_category_roles", [%{category_id: secret.id, role_id: role.id}])
      author = user_fixture()
      thread = thread_fixture(secret, admin, %{title: "Hidden plans"})
      {:ok, reply} = Discussion.create_post(thread, author, %{body: "secret"})
      Discussion.like_post(reply, admin)
      Badges.grant_earned([author.id])

      conn
      |> visit(~p"/badges/#{badge("Welcome").id}")
      |> assert_has("#grantees", text: "@#{author.username}")
      |> refute_has("#grantees", text: "Hidden plans")

      conn
      |> log_in_as(admin)
      |> visit(~p"/badges/#{badge("Welcome").id}")
      |> assert_has("#grantees", text: "Hidden plans")
    end

    test "admins grant on the badge page and manage badges", %{conn: conn, admin: admin} do
      member = user_fixture()

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/badges")
      |> fill_in("Name", with: "Helper")
      |> fill_in("Description", with: "Helped out")
      |> click_button("Save badge")
      |> assert_has("#flash-info", text: "Saved Helper.")
      |> click_link("Helper")
      |> fill_in("Grant to (username)", with: member.username)
      |> click_button("Grant")
      |> assert_has("#flash-info", text: "Granted Helper to @#{member.username}.")
      |> click_button("Revoke")
      |> assert_has("#flash-info", text: "Revoked.")
    end

    test "members pick a title in settings; it shows on the profile", %{conn: conn, admin: admin} do
      member = user_fixture()

      {:ok, titled} =
        Badges.create_badge(
          %{"name" => "Sage", "icon" => "hero-star", "allow_title" => "true"},
          admin
        )

      {:ok, _} = Badges.grant(titled, member, admin)

      conn
      |> log_in_as(member)
      |> visit(~p"/settings/profile")
      |> select("Title", option: "Sage")
      |> click_button("Set title")
      |> assert_has("#flash-info", text: "Title updated.")
      |> visit(~p"/users/#{member}")
      |> assert_has("#user-title", text: "Sage")
    end
  end

  test "export and account deletion", %{admin: admin} do
    member = user_fixture()
    {:ok, badge} = Badges.create_badge(%{"name" => "Helper", "icon" => "hero-gift"}, admin)
    {:ok, _} = Badges.grant(badge, member, admin, "Thanks")

    assert %{badges: [%{badge: "Helper", reason: "Thanks"}]} = AccountExport.build(member)
    {:ok, _} = AccountDeletion.delete_account(member, member.username)
    refute Repo.exists?(where(UserBadge, user_id: ^member.id))
  end
end
