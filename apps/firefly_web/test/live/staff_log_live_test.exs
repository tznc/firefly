defmodule FireflyWeb.StaffLogLiveTest do
  use FireflyWeb.ConnCase

  import Ecto.Query, only: [from: 2]

  alias Firefly.{Accounts, Discussion, Repo}
  alias Firefly.Accounts.UserAdmin
  alias Firefly.Discussion.Category
  alias Firefly.Moderation.StaffAction

  setup do
    admin = admin_fixture(%{username: "boss"})
    author = user_fixture(%{username: "author"})
    category = category_fixture("Elixir")
    thread = thread_fixture(category, author, %{title: "Supervisors"})
    %{admin: admin, author: author, category: category, thread: thread}
  end

  test "only admins see the staff log", %{conn: conn, author: author} do
    conn
    |> log_in_as(author)
    |> visit(~p"/staff/log")
    |> assert_path(~p"/")
    |> assert_has("#flash-error", text: "You are not allowed to do that.")

    conn
    |> log_in_as(admin_fixture())
    |> visit(~p"/staff")
    |> assert_has("#staff-nav a", text: "Staff log")
  end

  test "moderating from the thread page shows in the log, linking to the thread", ctx do
    %{conn: conn, admin: admin, thread: thread} = ctx

    conn
    |> log_in_as(admin)
    |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}")
    |> click_button("#moderation button", "Close")
    |> visit(~p"/staff/log")
    |> assert_has("#staff-log td", text: "boss")
    |> assert_has("#staff-log td", text: "Closed thread")
    |> assert_has(
      ~s{#staff-log td.target a[href="/categories/#{thread.category_id}/threads/#{thread.id}"]},
      text: "Supervisors"
    )
  end

  test "filters by action and staff member, and shows deleted targets' details", ctx do
    %{conn: conn, admin: admin, thread: thread} = ctx
    other = admin_fixture(%{username: "mod"})
    {:ok, thread} = Discussion.pin_thread(thread, true, admin)
    {:ok, _} = Discussion.close_thread(thread, true, other)
    {:ok, _} = Discussion.delete_thread(thread, other)

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/log")
    |> assert_has("#staff-log tbody tr", count: 3)
    |> assert_has("td.target", text: "Deleted thread ##{thread.id}")
    |> assert_has("td.details", text: "category: Elixir")
    |> select("Action", option: "Pinned thread")
    |> assert_has("#staff-log tbody tr", count: 1)
    |> assert_has("td", text: "boss")
    |> select("Action", option: "Any action")
    |> select("Staff", option: "mod")
    |> assert_has("#staff-log tbody tr", count: 2)
    |> refute_has("td", text: "Pinned thread")
  end

  test "edits show before and after", %{conn: conn, admin: admin, category: category} do
    {:ok, _} = Discussion.update_category(category, %{description: "BEAM talk"}, admin)

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/log")
    |> assert_has("td.details ins", text: "BEAM talk")
    |> assert_has("td.target a", text: "Elixir")
  end

  test "the log is paginated", %{conn: conn, admin: admin} do
    now = NaiveDateTime.utc_now()

    entries =
      for i <- 1..51,
          do: %{
            actor_id: admin.id,
            action: "thread.pin",
            target_type: "thread",
            target_id: i,
            details: %{},
            inserted_at: now
          }

    Repo.insert_all(StaffAction, entries)

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/log")
    |> assert_has("#staff-log tbody tr", count: 50)
    |> click_link("nav[aria-label=Pagination] a", "2")
    |> assert_has("#staff-log tbody tr", count: 1)
  end

  describe "users admin edits" do
    test "are logged with what changed", %{conn: conn, admin: admin, author: author} do
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/users/#{author.id}")
      |> within("#account-form", fn session ->
        session
        |> fill_in("Name", with: "Writer")
        |> click_button("Save account")
      end)

      assert [%{action: "user.edit", target_type: "user", details: details}] =
               Repo.all(StaffAction)

      assert details["name"] == %{"before" => author.name, "after" => "Writer"}
    end

    test "granting and revoking roles is logged on the user", %{conn: conn, admin: admin} do
      member = user_fixture(%{username: "promoted"})

      session =
        conn
        |> log_in_as(admin)
        |> visit(~p"/staff/users/#{member.id}")
        |> click_button("Grant moderator")

      assert Accounts.moderator?(member)
      session |> click_button("Revoke moderator")
      refute Accounts.moderator?(member)

      assert [grant, revoke] = Repo.all(from(a in StaffAction, order_by: a.id))

      assert {grant.action, grant.target_type, grant.target_id} ==
               {"role.grant", "user", member.id}

      assert revoke.action == "role.revoke"
      assert revoke.details == %{"role" => "moderator", "username" => "promoted"}
    end
  end

  test "moving a thread to its own category isn't logged", %{admin: admin, thread: thread} do
    category = Repo.get!(Category, thread.category_id)
    assert {:ok, _} = Discussion.move_thread(thread, category, admin)
    assert Repo.all(StaffAction) == []
  end

  test "deleting an account scrubs who it was from the log", %{
    conn: conn,
    admin: admin,
    thread: thread
  } do
    {:ok, ada} =
      Accounts.register_user(%{
        username: "ada",
        email: "ada@example.com",
        password: "ada-password"
      })

    {:ok, ada} = Accounts.confirm_user(ada)
    {:ok, post} = Discussion.create_post(thread, ada, %{body: "Ada's reply"})
    {:ok, _} = Discussion.delete_post(post, admin)

    {:ok, ada} = UserAdmin.update(ada, %{"email" => "ada@new.example"}, admin)
    {:ok, _} = UserAdmin.set_staff_role(ada, "moderator", true, admin)
    {:ok, _} = UserAdmin.set_staff_role(ada, "moderator", false, admin)

    log = fn -> Repo.all(from(a in StaffAction, select: a.details)) |> Jason.encode!() end
    assert log.() =~ "ada@example.com"
    assert log.() =~ ~s{"ada"}

    {:ok, _} =
      Firefly.Accounts.AccountDeletion.delete_account(Accounts.get_user!(ada.id), "ada-password")

    refute log.() =~ "ada@"
    refute log.() =~ ~s{"ada"}
    assert log.() =~ "deleted-user-#{ada.id}"
    assert Repo.aggregate(StaffAction, :count) == 4
  end
end
