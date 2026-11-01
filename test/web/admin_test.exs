defmodule FirestormWeb.Web.AdminTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  defp admin_fixture do
    user = user_fixture()
    {:ok, role} = Forums.create_role("admin")
    {:ok, _} = Forums.add_role(user, role)
    user
  end

  test "visitors are sent away from /admin", %{conn: conn} do
    conn
    |> visit("/admin")
    |> assert_path(~p"/")
    |> assert_has("#flash-error", text: "You must be an administrator to access this page.")
  end

  test "non-admin users are sent away from /admin", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit("/admin/forums/category")
    |> assert_path(~p"/")
  end

  test "admins can use the Kaffy admin", %{conn: conn} do
    category_fixture("Elixir")
    user_fixture(%{username: "listed_user"})
    conn = log_in_as(conn, admin_fixture())

    conn |> visit("/admin/dashboard") |> assert_has("title", text: "Firestorm Admin")
    conn |> visit("/admin/forums/category") |> assert_has("td", text: "Elixir")

    conn
    |> visit("/admin/accounts/user")
    |> assert_has("td", text: "listed_user")
    |> refute_has("th", text: "Password hash")
    |> refute_has("th", text: "Api token")
  end
end
