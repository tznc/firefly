defmodule FirestormWeb.Web.AuthLiveTest do
  use FirestormWeb.Web.ConnCase

  require Phoenix.LiveViewTest

  alias FirestormWeb.Forums

  @password "s3cret-password"

  defp register(username) do
    {:ok, user} =
      Forums.register_user(%{
        username: username,
        email: "#{username}@example.com",
        password: @password
      })

    user
  end

  test "the login page offers GitHub, registration and username/password", %{conn: conn} do
    conn
    |> visit(~p"/")
    |> click_link("Log in")
    |> assert_has(~s(a[href="/auth/github"]), text: "Log in with GitHub")
    |> assert_has(~s(a[href="/register"]), text: "Create Account")
    |> assert_has(~s(a[href="/auth/identity"]), text: "Sign In")
  end

  test "the login form requires a username and password", %{conn: conn} do
    conn
    |> visit(~p"/auth/identity")
    |> click_button("Log in")
    |> assert_has("p", text: "can't be blank", count: 2)
  end

  test "logging in with the right password", %{conn: conn} do
    register("newbie")

    conn
    |> visit(~p"/auth/identity")
    |> fill_in("Username", with: "newbie")
    |> fill_in("Password", with: @password)
    |> click_button("Log in")
    |> assert_path(~p"/")
    |> assert_has("#flash-info", text: "Successfully authenticated.")
    |> assert_has("nav a", text: "Your profile")
  end

  test "logging in never registers an unknown username", %{conn: conn} do
    conn
    |> visit(~p"/auth/identity")
    |> fill_in("Username", with: "stranger")
    |> fill_in("Password", with: @password)
    |> click_button("Log in")
    |> assert_path(~p"/auth/identity")
    |> assert_has("#flash-error", text: "No user found with that username or password")

    refute Forums.get_user_by_username("stranger")
  end

  test "a wrong password is rejected", %{conn: conn} do
    register("newbie")

    conn
    |> visit(~p"/auth/identity")
    |> fill_in("Username", with: "newbie")
    |> fill_in("Password", with: "wrong!")
    |> click_button("Log in")
    |> assert_path(~p"/auth/identity")
    |> assert_has("#flash-error", text: "No user found with that username or password")
  end

  test "registering creates the account and logs you in", %{conn: conn} do
    conn
    |> visit(~p"/register")
    |> fill_in("Username", with: "newbie")
    |> fill_in("Email", with: "newbie@example.com")
    |> fill_in("Password", with: @password)
    |> click_button("Create account")
    |> assert_path(~p"/")
    |> assert_has("#flash-info", text: "Successfully authenticated.")
    |> assert_has("nav a", text: "Your profile")

    assert %{email: "newbie@example.com"} = Forums.get_user_by_username("newbie")
  end

  test "registration explains invalid input", %{conn: conn} do
    conn
    |> visit(~p"/register")
    |> fill_in("Username", with: "new bie")
    |> fill_in("Email", with: "nope")
    |> fill_in("Password", with: "abc")
    |> click_button("Create account")
    |> assert_path(~p"/register")
    |> assert_has("p", text: "can only contain letters, numbers, - and _")
    |> assert_has("p", text: "must be a valid email")
    |> assert_has("p", text: "should be at least 8 character(s)")

    refute Forums.get_user_by_username("new bie")
  end

  test "registration rejects a taken username", %{conn: conn} do
    register("newbie")

    conn
    |> visit(~p"/register")
    |> fill_in("Username", with: "newbie")
    |> fill_in("Email", with: "other@example.com")
    |> fill_in("Password", with: @password)
    |> click_button("Create account")
    |> assert_has("p", text: "has already been taken")
  end

  test "registration ignores bots that fill in the hidden honeypot field", %{conn: conn} do
    {:ok, view, _html} = Phoenix.LiveViewTest.live(conn, ~p"/register")

    html =
      Phoenix.LiveViewTest.render_submit(view, "save", %{
        "user" => %{
          "username" => "spambot",
          "email" => "bot@example.com",
          "password" => "s3cret-password",
          "website" => "https://spam.example"
        }
      })

    assert html =~ "Registration failed"
    refute Forums.get_user_by_username("spambot")
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

  test "logging out requires DELETE (a GET can't log you out)", %{conn: conn} do
    user = user_fixture()
    conn = conn |> log_in_as(user) |> get("/auth/logout")

    assert get_session(conn, :current_user) == user.id
    refute Phoenix.Flash.get(conn.assigns.flash, :info) == "You have been logged out!"
  end

  test "GitHub callbacks pass the GitHub user id", %{conn: conn} do
    auth = %Ueberauth.Auth{
      provider: :github,
      uid: 4242,
      info: %Ueberauth.Auth.Info{nickname: "octocat", name: "Octo", email: "octo@example.com"}
    }

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> fetch_flash()
      |> assign(:ueberauth_auth, auth)
      |> FirestormWeb.Web.AuthController.callback(%{})

    assert redirected_to(conn) == ~p"/"
    assert Forums.get_user!(get_session(conn, :current_user)).github_uid == "4242"
  end
end
