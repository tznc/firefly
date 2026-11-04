defmodule FireflyWeb.E2E.StaffAdminTest do
  @moduledoc """
  The staff admin in a real browser: impersonating a member (the `.link
  method="post"` button, its confirmation dialog, the banner on every
  page) and coming back; reordering categories by drag and drop and from
  the keyboard (the `Sortable` hook).
  """
  use FireflyWeb.E2ECase, async: false

  import Ecto.Query, only: [from: 2]

  alias Firefly.Discussion
  alias Firefly.Discussion.Category
  alias Firefly.Moderation.StaffAction
  alias Firefly.Repo

  test "an admin impersonates a member and stops", %{conn: conn} do
    admin_fixture("ada")
    member = member_fixture("bob")

    conn
    |> log_in("ada")
    |> visit("/staff/users/#{member.id}")
    |> assert_has("[data-phx-main].phx-connected")
    |> click_link("#impersonate", "Impersonate")
    |> assert_path("/")
    |> assert_has("#impersonation-banner", text: "You're seeing the site as @bob.")
    |> assert_has("nav a", text: "Your profile")
    |> refute_has("nav a", text: "Admin")
    |> click_link("#impersonation-banner a", "Stop impersonating")
    |> assert_path("/staff/users/#{member.id}")
    |> refute_has("#impersonation-banner")
    |> assert_has("#staff-nav a", text: "Users")

    assert Repo.all(from(a in StaffAction, order_by: a.id, select: a.action)) ==
             ["user.impersonate", "user.impersonate_stop"]
  end

  describe "reordering categories" do
    setup do
      admin_fixture("ada")
      {:ok, alpha} = Discussion.create_category(%{title: "Alpha"})
      {:ok, beta} = Discussion.create_category(%{title: "Beta"})
      {:ok, child} = Discussion.create_category(%{title: "Child", parent_id: alpha.id})
      %{alpha: alpha, beta: beta, child: child}
    end

    test "dragging a row's handle reorders it, and into another category", context do
      %{conn: conn, alpha: alpha, beta: beta, child: child} = context

      conn
      |> log_in("ada")
      |> visit("/staff/categories")
      |> assert_has("[data-phx-main].phx-connected")
      # Beta's handle onto the top edge of Alpha's row: Beta goes first.
      |> drag("#category-#{beta.id} [data-sortable-handle]",
        to: "#category-#{alpha.id} > [data-sortable-row]",
        playwright: [targetPosition: %{x: 40, y: 4}]
      )
      |> assert_has("#categories > li:first-child", text: "Beta")
      # Child into Beta's (empty) subcategory list.
      |> drag("#category-#{child.id} [data-sortable-handle]", to: "#subcategories-#{beta.id}")
      |> assert_has("#subcategories-#{beta.id}", text: "Child")
      |> assert_has("#flash-error", count: 0)

      eventually(fn -> top_level() == ["Beta", "Alpha"] end)
      eventually(fn -> Repo.get!(Category, child.id).parent_id == beta.id end)
    end

    test "Space picks a row up, arrows move it, Space drops it, Escape cancels", context do
      %{conn: conn, beta: beta} = context
      handle = "#category-#{beta.id} [data-sortable-handle]"

      conn
      |> log_in("ada")
      |> visit("/staff/categories")
      |> assert_has("[data-phx-main].phx-connected")
      |> press(handle, " ")
      |> assert_has("#category-order-status", text: "Beta picked up, position 2 of 2.")
      |> press(handle, "ArrowUp")
      |> assert_has("#category-order-status", text: "Beta: position 1 of 2.")
      |> press(handle, "Escape")
      |> assert_has("#category-order-status",
        text: "Move cancelled. Beta is back at position 2 of 2."
      )
      |> assert_has("#categories > li:first-child", text: "Alpha")
      |> press(handle, " ")
      |> press(handle, "ArrowUp")
      |> press(handle, " ")
      |> assert_has("#category-order-status", text: "Beta dropped at position 1 of 2.")
      |> assert_has("#categories > li:first-child", text: "Beta")

      eventually(fn -> top_level() == ["Beta", "Alpha"] end)
    end
  end

  # The page moves the row before the server has saved it.
  defp eventually(check, tries \\ 40) do
    cond do
      check.() ->
        :ok

      tries == 0 ->
        flunk("the change never reached the database")

      true ->
        Process.sleep(50)
        eventually(check, tries - 1)
    end
  end

  defp top_level do
    Repo.all(
      from(c in Category,
        where: is_nil(c.parent_id),
        order_by: [c.position, c.title],
        select: c.title
      )
    )
  end
end
