defmodule FirestormWeb.Web.LayoutTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  test "pages load the app's CSS and JS", %{conn: conn} do
    html = conn |> get(~p"/categories") |> html_response(200)
    assert html =~ ~s(href="/assets/css/app.css")
    assert html =~ ~s(src="/assets/js/app.js")
  end

  test "pages carry the Firefly brand: icons, manifest, wordmark", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(href="/images/firefly-icon.svg")
    assert html =~ ~s(href="/images/apple-touch-icon.png")
    assert html =~ ~s(href="/manifest.json")
    assert html =~ "<title data-default=\"Firefly\""

    conn |> visit(~p"/") |> assert_has("header span", text: "Firefly")

    manifest = conn |> get("/manifest.json") |> response(200) |> Jason.decode!()
    assert manifest["name"] == "Firefly"
    assert conn |> get("/images/firefly-icon.svg") |> response(200) =~ "<title>Firefly</title>"
  end

  test "visitors see a log in link and the forum navigation", %{conn: conn} do
    conn
    |> visit(~p"/categories")
    |> assert_has(~s(nav a[href="/login"]), text: "Log in")
    |> assert_has(~s(nav a[href="/users"]), text: "Users")
    |> refute_has(~s(nav a[href="/admin"]))
  end

  test "users see their links; admins also see the admin link", %{conn: conn} do
    user = user_fixture()

    conn
    |> log_in_as(user)
    |> visit(~p"/categories")
    |> assert_has(~s(nav a[href="/threads/watching"]), text: "Watching")
    |> assert_has(~s(nav a[href="/users/#{user.id}"]), text: "Your profile")
    |> refute_has(~s(nav a[href="/admin"]))

    {:ok, role} = Forums.create_role("admin")
    {:ok, _} = Forums.add_role(user, role)

    conn
    |> log_in_as(user)
    |> visit(~p"/categories")
    |> assert_has(~s(nav a[href="/admin"]), text: "Admin")
  end

  test "highlights the current page", %{conn: conn} do
    conn |> visit(~p"/users") |> assert_has(~s(nav a.menu-active[href="/users"]))
  end

  test "sets the page title", %{conn: conn} do
    category = category_fixture("Elixir")
    conn |> visit(~p"/categories/#{category}") |> assert_has("title", text: "Elixir - Firefly")
  end
end
