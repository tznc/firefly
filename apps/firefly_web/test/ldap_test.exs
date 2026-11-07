defmodule FireflyWeb.LDAPTest do
  # The directory's configuration is global.
  use FireflyWeb.ConnCase, async: false

  alias Firefly.{LDAPTestDirectory, Repo, SiteSettings}
  alias Firefly.Accounts.{Auth, TwoFactor, User, UserIdentity}

  defp logged_in_user(conn) do
    case session_user_id(conn) do
      nil -> nil
      id -> Repo.get(User, id)
    end
  end

  defp ldap_login(conn, username, password),
    do:
      post(conn, ~p"/login/ldap", %{"ldap" => %{"username" => username, "password" => password}})

  test "the form isn't there without a directory", %{conn: conn} do
    LDAPTestDirectory.configure(host: nil)
    conn |> visit(~p"/login/ldap") |> assert_path(~p"/login")
    conn |> visit(~p"/login") |> refute_has("#login-ldap")
    assert redirected_to(ldap_login(build_conn(), "fry", "fry")) == ~p"/login"
  end

  describe "with OpenLDAP" do
    @describetag :ldap

    setup do
      LDAPTestDirectory.configure()
    end

    test "logs in from the login page's button", %{conn: conn} do
      conn
      |> visit(~p"/login")
      |> click_link("Log in with Planet Express")
      |> assert_path(~p"/login/ldap")
      |> fill_in("Username", with: "fry")
      |> fill_in("Password", with: "fry")
      |> click_button("Log in")
      |> assert_has("#flash-info", text: "Successfully authenticated")

      assert Repo.get_by(UserIdentity, provider: "ldap").info["nickname"] == "fry"
    end

    test "a wrong password goes back to the form", %{conn: conn} do
      conn = ldap_login(conn, "fry", "nope")
      assert redirected_to(conn) == ~p"/login/ldap"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Wrong Planet Express username or password."

      refute logged_in_user(conn)
    end

    test "is rate limited like password logins", %{conn: conn} do
      original = Application.get_env(:firefly, Firefly.RateLimit)
      on_exit(fn -> Application.put_env(:firefly, Firefly.RateLimit, original) end)
      limits = Keyword.put(original[:limits], :login, {1, 60_000})
      Application.put_env(:firefly, Firefly.RateLimit, Keyword.put(original, :limits, limits))

      ldap_login(conn, "leela", "nope")
      conn = ldap_login(build_conn(), "leela", "leela")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "too often"
      refute logged_in_user(conn)
    end

    test "asks members with two-factor for their second factor", %{conn: conn} do
      {:ok, user} = Firefly.Accounts.Auth.LDAP.login("fry", "fry")
      secret = TwoFactor.new_secret()
      code = NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30)
      {:ok, _codes} = TwoFactor.enable_totp(user, secret, code)

      conn = ldap_login(conn, "fry", "fry")
      assert redirected_to(conn) == ~p"/login/two-factor"
      refute logged_in_user(conn)
    end

    test "respects closed registrations", %{conn: conn} do
      {:ok, _} = SiteSettings.update(%{"allow_registrations" => "false"}, admin_fixture())
      conn = ldap_login(conn, "fry", "fry")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "New registrations are closed."
      refute logged_in_user(conn)
    end

    test "can replace local passwords", %{conn: conn} do
      {:ok, _} = SiteSettings.update(%{"ldap_replaces_password" => "true"}, admin_fixture())

      refute Auth.password_login?()
      conn |> visit(~p"/auth/identity") |> assert_path(~p"/login/ldap")
      conn |> visit(~p"/register") |> assert_path(~p"/login")

      conn
      |> visit(~p"/login")
      |> assert_has("#login-ldap", text: "Log in with Planet Express")
      |> refute_has("a", text: "Create Account")
    end

    test "connects the directory account from the settings", %{conn: conn} do
      user = user_fixture()
      conn = log_in_as(conn, user)
      conn |> visit(~p"/settings/logins") |> assert_has("#login-ldap", text: "Planet Express")

      conn = ldap_login(conn, "leela", "leela")
      assert redirected_to(conn) == ~p"/settings/logins"
      assert Repo.get_by(UserIdentity, provider: "ldap").user_id == user.id
    end
  end
end
