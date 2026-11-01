defmodule FirestormWeb.Web.AdminTest do
  use FirestormWeb.Web.ConnCase

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

  test "the admin uses the Firefly theme and links back to the forum", %{conn: conn} do
    conn = log_in_as(conn, admin_fixture())

    html = conn |> get("/admin/forums/category") |> html_response(200)
    assert html =~ ~s(href="/assets/css/admin.css")
    assert html =~ ~s(href="/images/firefly-icon.svg")
    assert html =~ "phx:theme"

    conn
    |> visit("/admin/forums/category")
    |> assert_has(~s(.sidebar a[href="/"]), text: "Back to Firefly")
  end

  test "the admin home is the categories list", %{conn: conn} do
    conn
    |> log_in_as(admin_fixture())
    |> visit("/admin")
    |> assert_path("/admin/forums/category")
  end

  test "admins can use the Kaffy admin", %{conn: conn} do
    category_fixture("Elixir")
    user_fixture(%{username: "listed_user"})
    conn = log_in_as(conn, admin_fixture())

    conn
    |> visit("/admin/dashboard")
    |> assert_has("title", text: "Firefly Admin")
    |> assert_has(~s(footer a[href="https://tznc.dev"]), text: "tznc.dev")

    conn |> visit("/admin/forums/category") |> assert_has("td", text: "Elixir")

    conn
    |> visit("/admin/accounts/user")
    |> assert_has("td", text: "listed_user")
    |> refute_has("th", text: "Password hash")
    |> refute_has("th", text: "Api token")
  end

  test "admins can't read private messages through the notifications admin", %{conn: conn} do
    {:ok, _} = FirestormWeb.Notifications.start_link()
    alice = user_fixture()
    bob = user_fixture()

    {:ok, _} =
      FirestormWeb.Messages.start_conversation(alice, %{
        "recipients" => bob.username,
        "title" => "Hush",
        "body" => "xylophone confidential"
      })

    :sys.get_state(FirestormWeb.Notifications)
    [notification] = FirestormWeb.Forums.notifications_for(bob)
    conn = log_in_as(conn, admin_fixture())

    for path <- [
          "/admin/accounts/notification",
          "/admin/accounts/notification/#{notification.id}"
        ] do
      html = conn |> get(path) |> html_response(200)
      refute html =~ "xylophone"
    end
  end
end
