defmodule FireflyWeb.E2E.StaffAdminTest do
  @moduledoc """
  The staff admin in a real browser: impersonating a member (the `.link
  method="post"` button, its confirmation dialog, the banner on every
  page) and coming back.
  """
  use FireflyWeb.E2ECase, async: false

  import Ecto.Query, only: [from: 2]

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
end
