defmodule FirestormWeb.Web.LayoutTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  test "visitors see a log in link and the forum navigation", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/categories")

    assert html =~ ~s(href="/assets/css/app.css")
    assert html =~ ~s(src="/assets/js/app.js")
    assert has_element?(view, ~s(nav a[href="/login"]), "Log in")
    assert has_element?(view, ~s(nav a[href="/users"]), "Users")
    refute has_element?(view, ~s(nav a[href="/admin"]))
  end

  test "users see their links; admins also see the admin link", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(log_in_as(conn, user), ~p"/categories")

    assert has_element?(view, ~s(nav a[href="/threads/watching"]), "Watching")
    assert has_element?(view, ~s(nav a[href="/users/#{user.id}"]), "Your profile")
    refute has_element?(view, ~s(nav a[href="/admin"]))

    {:ok, role} = Forums.create_role("admin")
    {:ok, _} = Forums.add_role(user, role)
    {:ok, view, _html} = live(log_in_as(conn, user), ~p"/categories")
    assert has_element?(view, ~s(nav a[href="/admin"]), "Admin")
  end

  test "highlights the current page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users")
    assert has_element?(view, ~s(nav a.menu-active[href="/users"]))
  end

  test "sets the page title", %{conn: conn} do
    category = category_fixture("Elixir")
    {:ok, _view, html} = live(conn, ~p"/categories/#{category}")

    assert html =~
             "<title data-default=\"Firestorm\" data-suffix=\" - Firestorm\">Elixir - Firestorm</title>"
  end
end
