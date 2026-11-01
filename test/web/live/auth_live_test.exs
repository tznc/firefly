defmodule FirestormWeb.Web.AuthLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  test "the login page offers GitHub and username/password", %{conn: conn} do
    conn
    |> visit(~p"/")
    |> click_link("Log in")
    |> assert_has(~s(a[href="/auth/github"]), text: "Log in with GitHub")
    |> assert_has(~s(a[href="/auth/identity"]), text: "Create Account")
  end

  test "the identity form requires a username and password", %{conn: conn} do
    conn
    |> visit(~p"/auth/identity")
    |> click_button("Log in or register")
    |> assert_has("p", text: "can't be blank", count: 2)
  end

  test "registering through the identity form logs you in", %{conn: conn} do
    conn
    |> visit(~p"/auth/identity")
    |> fill_in("Username", with: "newbie")
    |> fill_in("Password", with: "s3cret!")
    |> click_button("Log in or register")
    |> assert_path(~p"/")
    |> assert_has("#flash-info", text: "Successfully authenticated.")
    |> assert_has("nav a", text: "Your profile")

    assert Forums.get_user_by_username("newbie")
  end

  test "a wrong password is rejected", %{conn: conn} do
    {:ok, _} = Forums.login_or_register_from_identity(%{username: "newbie", password: "s3cret!"})

    conn
    |> visit(~p"/auth/identity")
    |> fill_in("Username", with: "newbie")
    |> fill_in("Password", with: "wrong!")
    |> click_button("Log in or register")
    |> assert_path(~p"/auth/identity")
    |> assert_has("#flash-error", text: "No user found with that username or password")
  end

  test "a too-short password on registration explains why", %{conn: conn} do
    conn
    |> visit(~p"/auth/identity")
    |> fill_in("Username", with: "newbie")
    |> fill_in("Password", with: "abc")
    |> click_button("Log in or register")
    |> assert_has("#flash-error", text: "password should be at least 6")
  end

  test "logging out clears the session", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/")
    |> click_link("Log out")
    |> assert_path(~p"/")
    |> assert_has("#flash-info", text: "You have been logged out!")
    |> assert_has("nav a", text: "Log in")
  end

  test "an unknown provider redirects to the login page", %{conn: conn} do
    conn
    |> visit("/auth/myspace")
    |> assert_path(~p"/login")
    |> assert_has("#flash-error", text: "Unknown login provider.")
  end
end
