defmodule FireflyWeb.SecurityLogTest do
  use FireflyWeb.ConnCase, async: true

  alias Firefly.{Accounts, Security}

  defp password_user do
    username = "member#{System.unique_integer([:positive])}"

    {:ok, user} =
      Accounts.register_user(%{
        username: username,
        email: "#{username}@example.com",
        password: "right-password"
      })

    user
  end

  defp attempt(conn, username, password) do
    post(conn, "/auth/identity/callback", %{
      "user" => %{"username" => username, "password" => password}
    })
  end

  test "logins and failed attempts are recorded with the client", %{conn: conn} do
    user = password_user()

    conn
    |> put_req_header("user-agent", "TestBrowser/1.0")
    |> attempt(user.username, "wrong-password")

    assert get_session(attempt(build_conn(), user.username, "right-password"), :current_user)

    assert [
             %{kind: "login.success", details: %{"method" => "password"}, ip: "127.0.0.1"},
             %{kind: "login.failure", user_agent: "TestBrowser/1.0"} = failure
           ] = Security.for_user(user)

    assert failure.details == %{"method" => "password", "username" => user.username}
  end

  test "API logins too", %{conn: conn} do
    user = password_user()
    params = %{"user" => %{"username" => user.username, "password" => "wrong"}}
    assert json_response(post(conn, "/api/v1/auth/identity", params), 401)
    params = put_in(params["user"]["password"], "right-password")
    assert json_response(post(build_conn(), "/api/v1/auth/identity", params), 200)

    assert ~w(login.success api_key.create login.failure) ==
             user |> Security.for_user() |> Enum.map(& &1.kind)
  end

  test "members see their own activity in their security settings", %{conn: conn} do
    user = user_fixture()
    other = user_fixture()
    Security.record("passkey.add", user, %{name: "Phone"}, ip: "192.0.2.7")
    Security.record("passkey.add", other, %{name: "Not mine"}, ip: "192.0.2.8")

    conn
    |> log_in_as(user)
    |> visit(~p"/settings/security")
    |> assert_has("#my-security-events td", text: "Passkey added")
    |> assert_has("#my-security-events td", text: "192.0.2.7")
    |> refute_has("#my-security-events td", text: "Not mine")
  end

  test "admins see and filter everyone's at /staff/security", %{conn: conn} do
    alice = user_fixture()
    bob = user_fixture()
    Security.record("login.success", alice, %{method: "password"}, ip: "192.0.2.10")
    Security.record("login.failure", bob, %{method: "password"}, ip: "198.51.100.20")

    session =
      conn
      |> log_in_as(admin_fixture())
      |> visit(~p"/staff/security")
      |> assert_has("#security-events td", text: alice.username)
      |> assert_has("#security-events td", text: bob.username)

    session
    |> select("Event", option: "Failed login")
    |> assert_has("#security-events td", text: bob.username)
    |> refute_has("#security-events td", text: alice.username)

    session
    |> visit(~p"/staff/security?q=192.0.2.")
    |> assert_has("#security-events td", text: alice.username)
    |> refute_has("#security-events td", text: bob.username)
  end

  test "members can't see the staff page", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/security")
    |> assert_path(~p"/")
  end
end
