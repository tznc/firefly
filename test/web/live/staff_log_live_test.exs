defmodule FirestormWeb.Web.StaffLogLiveTest do
  use FirestormWeb.Web.ConnCase

  import Ecto.Query, only: [from: 2]

  alias FirestormWeb.{Forums, Repo}
  alias FirestormWeb.Forums.{Category, StaffAction}

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

    conn |> log_in_as(admin_fixture()) |> visit(~p"/") |> assert_has("nav a", text: "Staff log")
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
    {:ok, thread} = Forums.pin_thread(thread, true, admin)
    {:ok, _} = Forums.close_thread(thread, true, other)
    {:ok, _} = Forums.delete_thread(thread, other)

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
    {:ok, _} = Forums.update_category(category, %{description: "BEAM talk"}, admin)

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

  describe "Kaffy admin edits" do
    test "are logged with what changed", %{conn: conn, admin: admin, category: category} do
      conn = log_in_as(conn, admin)

      put(conn, "/admin/forums/category/#{category.id}", %{"category" => %{"title" => "Erlang"}})
      assert Repo.get!(Category, category.id).title == "Erlang"

      assert [%{action: "admin.update", target_type: "category", details: details}] =
               Repo.all(StaffAction)

      assert details["title"] == %{"before" => "Elixir", "after" => "Erlang"}
    end

    test "granting and revoking roles is logged on the user", %{conn: conn, admin: admin} do
      member = user_fixture(%{username: "promoted"})
      role = Repo.get_by!(Forums.Role, name: "admin")
      conn = log_in_as(conn, admin)

      post(conn, "/admin/accounts/role_membership", %{
        "role_membership" => %{"user_id" => member.id, "role_id" => role.id}
      })

      assert Forums.admin?(member)
      membership = Repo.get_by!(Forums.RoleMembership, user_id: member.id)
      delete(conn, "/admin/accounts/role_membership/#{membership.id}")
      refute Forums.admin?(member)

      assert [grant, revoke] = Repo.all(from(a in StaffAction, order_by: a.id))

      assert {grant.action, grant.target_type, grant.target_id} ==
               {"role.grant", "user", member.id}

      assert revoke.action == "role.revoke"
      assert revoke.details == %{"role" => "admin", "username" => "promoted"}
    end
  end
end
