defmodule FirestormWeb.Web.AdminTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  defp admin_fixture do
    user = user_fixture()
    {:ok, role} = Forums.create_role("admin")
    {:ok, _} = Forums.add_role(user, role)
    user
  end

  test "visitors are redirected away from /admin", %{conn: conn} do
    conn = get(conn, "/admin")
    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "administrator"
  end

  test "non-admin users are redirected away from /admin", %{conn: conn} do
    conn = conn |> log_in_as(user_fixture()) |> get("/admin/forums/category")
    assert redirected_to(conn) == "/"
  end

  test "admins can use the Kaffy admin", %{conn: conn} do
    category_fixture("Elixir")
    user_fixture(%{username: "listed_user"})
    conn = log_in_as(conn, admin_fixture())

    assert html_response(get(conn, "/admin/dashboard"), 200) =~ "Firestorm Admin"
    assert html_response(get(conn, "/admin/forums/category"), 200) =~ "Elixir"

    users_html = html_response(get(conn, "/admin/accounts/user"), 200)
    assert users_html =~ "listed_user"
    refute users_html =~ "password_hash"
    refute users_html =~ "api_token"
  end
end
