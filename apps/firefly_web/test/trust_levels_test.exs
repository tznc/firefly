defmodule FireflyWeb.TrustLevelsTest do
  use FireflyWeb.ConnCase

  import Ecto.Query, only: [where: 2]
  import Firefly.DataCase, only: [errors_on: 1]

  alias Firefly.{Accounts, Discussion, Groups, Repo, TrustLevels}
  alias Firefly.Moderation.{Flags, Posting}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Policy, Post}
  alias Firefly.Moderation.StaffAction
  alias Firefly.Notifications.Notification
  alias Firefly.SiteSettings.SiteSetting

  setup do
    admin = admin_fixture()
    category = category_fixture("General")
    thread = thread_fixture(category, admin)
    %{admin: admin, category: category, thread: thread}
  end

  defp setting(key, value) do
    Repo.insert!(%SiteSetting{key: key, value: to_string(value)},
      on_conflict: [set: [value: to_string(value)]],
      conflict_target: :key
    )
  end

  defp at_level(level), do: user_fixture(%{trust_level: level})

  defp reload(user), do: Repo.get!(User, user.id)

  defp first_post(thread), do: hd(Repo.all(where(Post, thread_id: ^thread.id)))

  defp group_names(user) do
    user
    |> Repo.preload(:roles, force: true)
    |> Map.fetch!(:roles)
    |> Enum.map(& &1.name)
    |> Enum.filter(&TrustLevels.group?/1)
    |> Enum.sort()
  end

  # Days visited and posts read, as Firefly.Accounts.Visits records them.
  defp visit(user, days, posts_read) do
    for n <- 1..days do
      Repo.insert_all("user_visits", [
        %{user_id: user.id, visited_on: Date.add(Date.utc_today(), -n), posts_read: posts_read}
      ])
    end
  end

  defp enter_threads(user, category, admin, count) do
    for _ <- 1..count do
      thread = thread_fixture(category, admin)
      {:ok, _} = Discussion.mark_thread_read(user, thread)
    end
  end

  describe "the review" do
    test "registration starts at trust level 0, in its group" do
      {:ok, user} =
        Accounts.register_user(%{
          username: "newbie",
          email: "n@example.com",
          password: "password1"
        })

      assert user.trust_level == 0
      assert group_names(user) == ["trust_level_0"]
      assert TrustLevels.new_user?(user)
    end

    test "promotes to basic user once they've read enough, and notifies", ctx do
      user = at_level(0)
      TrustLevels.review()
      assert reload(user).trust_level == 0

      visit(user, 1, 30)
      enter_threads(user, ctx.category, ctx.admin, 5)
      TrustLevels.review()

      user = reload(user)
      assert user.trust_level == 1
      assert group_names(user) == ["trust_level_0", "trust_level_1"]

      assert [%Notification{kind: "promoted", subject: "You're now a basic user (trust level 1)"}] =
               Repo.all(where(Notification, user_id: ^user.id, kind: "promoted"))

      assert %StaffAction{actor_id: nil, details: %{"from" => 0, "to" => 1}} =
               Repo.get_by!(StaffAction, action: "user.trust_level", target_id: user.id)
    end

    test "promotes through several levels at once", ctx do
      user = at_level(0)
      liker = at_level(1)
      visit(user, 15, 10)
      enter_threads(user, ctx.category, ctx.admin, 20)

      for _ <- 1..3 do
        thread = thread_fixture(ctx.category, ctx.admin)
        {:ok, post} = Discussion.create_post(thread, user, %{body: "a reply"})
        Discussion.like_post(post, liker)
      end

      Discussion.like_post(first_post(ctx.thread), user)
      TrustLevels.review()

      assert reload(user).trust_level == 2
      assert group_names(reload(user)) == ~w(trust_level_0 trust_level_1 trust_level_2)
    end

    test "promotes to regular and demotes after the grace period", ctx do
      for {key, value} <- [
            {"tl3_requires_days_visited", 2},
            {"tl3_requires_topics_replied_to", 0},
            {"tl3_requires_topics_viewed", 0},
            {"tl3_requires_posts_read", 0},
            {"tl3_requires_topics_viewed_all_time", 1},
            {"tl3_requires_posts_read_all_time", 1},
            {"tl3_requires_likes_given", 0},
            {"tl3_requires_likes_received", 0}
          ],
          do: setting(key, value)

      user = at_level(2)
      visit(user, 2, 5)
      enter_threads(user, ctx.category, ctx.admin, 1)
      TrustLevels.review()
      assert reload(user).trust_level == 3

      # Short of the requirements now, but within the grace period.
      setting("tl3_requires_posts_read_all_time", 1000)
      TrustLevels.review()
      assert reload(user).trust_level == 3

      user
      |> reload()
      |> Ecto.Changeset.change(trust_level_changed_at: ~U[2020-01-01 00:00:00Z])
      |> Repo.update!()

      TrustLevels.review()
      assert reload(user).trust_level == 2
      assert group_names(reload(user)) == ~w(trust_level_0 trust_level_1 trust_level_2)
    end

    test "leaves locked levels, leaders and unconfirmed accounts alone", ctx do
      locked = at_level(0)
      {:ok, _} = TrustLevels.set_level(locked, 0, true, ctx.admin)
      leader = at_level(4)

      {:ok, unconfirmed} =
        Accounts.register_user(%{
          username: "unconf",
          email: "u@example.com",
          password: "password1"
        })

      for user <- [locked, unconfirmed] do
        visit(user, 1, 30)
        enter_threads(user, ctx.category, ctx.admin, 5)
      end

      TrustLevels.review()
      assert reload(locked).trust_level == 0
      assert reload(leader).trust_level == 4
      assert reload(unconfirmed).trust_level == 0
      assert TrustLevels.progress(reload(locked)) == nil
    end

    test "runs once an hour across nodes" do
      assert {"5 * * * *", Firefly.Jobs.Periodic.TrustLevels} in Firefly.Jobs.crontab()
      assert :ok = perform_job(Firefly.Jobs.Periodic.TrustLevels, %{})
    end

    test "progress lists what the next level needs", ctx do
      user = at_level(0)
      visit(user, 1, 12)
      enter_threads(user, ctx.category, ctx.admin, 5)

      assert {1, [entered, read]} = TrustLevels.progress(user)
      assert %{label: "Topics entered", have: 5, need: 5, met?: true} = entered
      # Opening the threads read their posts too.
      assert %{label: "Posts read", have: 17, need: 30, met?: false} = read
    end
  end

  describe "admins" do
    test "set and lock a level, staff-logged", %{conn: conn, admin: admin} do
      user = at_level(1)

      conn
      |> log_in_as(admin)
      |> visit(~p"/users/#{user}")
      |> assert_has("#user-trust-level", text: "basic user")
      |> within("#trust-level-form", fn session ->
        session
        |> select("Trust level", option: "leader (trust level 4)")
        |> check("Lock (the automatic review leaves it alone)")
      end)
      |> click_button("Set trust level")
      |> assert_has("#flash-info", text: "is now a leader (trust level 4)")

      user = reload(user)
      assert {user.trust_level, user.manual_locked_trust_level} == {4, 4}
      assert group_names(user) == Enum.map(0..4, &TrustLevels.group_name/1)

      assert %StaffAction{
               actor_id: actor_id,
               details: %{"from" => 1, "to" => 4, "locked" => true}
             } =
               Repo.get_by!(StaffAction, action: "user.trust_level", target_id: user.id)

      assert actor_id == admin.id
      assert Repo.get_by!(Notification, user_id: user.id, kind: "promoted")
    end

    test "members see their progress, not others' or the form", %{conn: conn} do
      user = at_level(0)
      other = at_level(1)

      conn
      |> log_in_as(user)
      |> visit(~p"/users/#{user}")
      |> assert_has("#trust-progress", text: "Toward basic user")
      |> refute_has("#trust-level-form")
      |> visit(~p"/users/#{other}")
      |> refute_has("#trust-progress")
    end
  end

  describe "gates" do
    test "new users can't start conversations or flag", %{thread: thread} do
      newbie = at_level(0)
      assert Posting.check(newbie, :new_conversation) == {:error, {:trust_level, 1}}
      assert Posting.message({:trust_level, 1}) =~ "basic user"
      assert :ok = Posting.check(at_level(1), :new_conversation)

      post = first_post(thread)
      refute Bodyguard.permit?(Policy, :flag_post, newbie, %{post: post, thread: thread})
      assert Bodyguard.permit?(Policy, :flag_post, at_level(1), %{post: post, thread: thread})
    end

    test "posts below approve_unless_trust_level wait for approval" do
      setting("approve_unless_trust_level", 2)
      assert Discussion.approval_required?(at_level(1))
      refute Discussion.approval_required?(at_level(2))
    end

    test "regulars rename and move others' threads; leaders also edit, pin and close", ctx do
      thread = thread_fixture(ctx.category, at_level(1))
      post = first_post(thread)
      params = %{post: post, thread: thread}
      [member, regular, leader] = Enum.map([2, 3, 4], &at_level/1)

      refute Bodyguard.permit?(Policy, :update_thread, member, thread)
      refute Bodyguard.permit?(Policy, :move_thread, member, thread)
      assert Bodyguard.permit?(Policy, :update_thread, regular, thread)
      assert Bodyguard.permit?(Policy, :move_thread, regular, thread)
      refute Bodyguard.permit?(Policy, :delete_thread, regular, thread)
      refute Bodyguard.permit?(Policy, :close_thread, regular, thread)
      refute Bodyguard.permit?(Policy, :edit_post, regular, params)

      assert Bodyguard.permit?(Policy, :close_thread, leader, thread)
      assert Bodyguard.permit?(Policy, :edit_post, leader, params)
      assert Bodyguard.permit?(Policy, :toggle_wiki, leader, nil)
      refute Bodyguard.permit?(Policy, :moderate_thread, leader, thread)
    end

    test "a leader closes a thread from its page", %{conn: conn, category: category} do
      thread = thread_fixture(category, at_level(1))

      conn
      |> log_in_as(at_level(4))
      |> visit(~p"/categories/#{category}/threads/#{thread}")
      |> refute_has("button", text: "Archive")
      |> click_button("Close")
      |> assert_has("#flash-info", text: "Thread closed.")
    end

    test "a regular's spam flag hides a new user's post at once", %{thread: thread} do
      {:ok, spam} = Discussion.create_post(thread, at_level(0), %{body: "buy now"})
      {:ok, _} = Flags.flag_post(spam, at_level(3), %{"reason" => "spam"})
      assert Discussion.get_post!(spam.id).hidden_at

      {:ok, reply} = Discussion.create_post(thread, at_level(1), %{body: "fine"})
      {:ok, _} = Flags.flag_post(reply, at_level(3), %{"reason" => "spam"})
      refute Discussion.get_post!(reply.id).hidden_at
    end
  end

  test "trust level groups' members can't be changed by hand", %{admin: admin} do
    group = Groups.get_by_name("trust_level_1")
    user = at_level(1)

    assert Groups.add_member(group, at_level(0).username, admin) == {:error, :automatic}
    assert Groups.remove_member(group, user, admin) == {:error, :automatic}
    assert Groups.remove_member(group, user, user) == {:error, :automatic}
    assert Groups.invite(group, user.username, admin) == {:error, :automatic}
    assert Groups.set_owner(group, user, true, admin) == {:error, :automatic}

    assert {:error, changeset} = Groups.update_settings(group, %{"membership" => "open"}, admin)
    assert "must be closed for a trust level group" in errors_on(changeset).membership
  end
end
