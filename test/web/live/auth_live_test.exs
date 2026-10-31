defmodule FirestormWeb.Web.AuthLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  test "the login page offers GitHub and username/password", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")

    assert has_element?(view, ~s(a[href="/auth/github"]), "Log in with GitHub")
    assert has_element?(view, ~s(a[href="/auth/identity"]), "Create Account")
  end

  test "the identity form requires a username and password", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/auth/identity")

    html = view |> form("#identity-form", user: %{username: "", password: ""}) |> render_submit()
    assert html =~ "can&#39;t be blank"
  end

  test "submitting the identity form posts to the identity callback", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/auth/identity")

    form = form(view, "#identity-form", user: %{username: "newbie", password: "s3cret!"})
    render_submit(form)

    conn = follow_trigger_action(form, conn)
    assert redirected_to(conn) == ~p"/"
    user = Forums.get_user_by_username("newbie")
    assert get_session(conn, :current_user) == user.id
  end

  describe "AuthController" do
    test "a wrong password redirects back with an error", %{conn: conn} do
      {:ok, _} =
        Forums.login_or_register_from_identity(%{username: "newbie", password: "s3cret!"})

      conn =
        post(conn, ~p"/auth/identity/callback", %{
          "user" => %{"username" => "newbie", "password" => "wrong!"}
        })

      assert redirected_to(conn) == ~p"/auth/identity"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "No user found"
      refute get_session(conn, :current_user)
    end

    test "a too-short password on registration explains why", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/identity/callback", %{
          "user" => %{"username" => "newbie", "password" => "abc"}
        })

      assert redirected_to(conn) == ~p"/auth/identity"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "password should be at least 6"
    end

    test "logging out clears the session", %{conn: conn} do
      conn = conn |> log_in_as(user_fixture()) |> delete(~p"/auth/logout")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :current_user)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "You have been logged out!"
    end

    test "an unknown provider redirects to the login page", %{conn: conn} do
      conn = get(conn, "/auth/myspace")
      assert redirected_to(conn) == ~p"/login"
    end
  end
end
