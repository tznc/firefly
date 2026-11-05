defmodule FireflyWeb.SessionsTest do
  use FireflyWeb.ConnCase, async: true

  alias Firefly.{Accounts, Repo, Security, SiteSettings}
  alias Firefly.Accounts.{UserAdmin, UserSession, UserSessions}

  @password "right-password"

  defp password_user do
    username = "member#{System.unique_integer([:positive])}"

    {:ok, user} =
      Accounts.register_user(%{
        username: username,
        email: "#{username}@example.com",
        password: @password
      })

    user
  end

  defp log_in(conn, user, remember \\ "true") do
    conn
    |> put_req_header(
      "user-agent",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) Gecko/20100101 Firefox/131.0"
    )
    |> post("/auth/identity/callback", %{
      "user" => %{"username" => user.username, "password" => @password, "remember_me" => remember}
    })
  end

  defp age(session, field, seconds) do
    session
    |> Ecto.Changeset.change([{field, DateTime.add(session.inserted_at, -seconds)}])
    |> Repo.update!()
  end

  test "the cookie holds only a session token, checked on every request", %{conn: conn} do
    user = password_user()
    conn = log_in(conn, user)

    assert %{"session_token" => token, "live_socket_id" => "user_sessions:" <> _} =
             get_session(conn)

    refute Map.has_key?(get_session(conn), "current_user")

    assert [%UserSession{device: "Firefox on macOS", ip: "127.0.0.1", remember: true} = session] =
             UserSessions.list(user)

    refute session.token_hash == token
    assert conn |> recycle() |> get(~p"/") |> html_response(200) =~ "Your profile"

    # Signed out from elsewhere: the very next request is anonymous.
    :ok = UserSessions.revoke(session)
    refute conn |> recycle() |> get(~p"/") |> html_response(200) =~ "Your profile"
  end

  test "keep me logged in: a cookie that brings the session back", %{conn: conn} do
    user = password_user()
    conn = log_in(conn, user)
    assert %{value: _, max_age: max_age} = conn.resp_cookies["_firefly_remember"]
    assert max_age == 30 * 86_400

    # A new browser session: no session cookie, only the remember cookie.
    remembered =
      build_conn()
      |> put_req_cookie("_firefly_remember", conn.resp_cookies["_firefly_remember"].value)
      |> get(~p"/")

    assert html_response(remembered, 200) =~ "Your profile"
    assert get_session(remembered, :session_token)

    forgetful = log_in(build_conn(), user, "false")
    refute forgetful.resp_cookies["_firefly_remember"]
    assert [%{remember: false}, %{remember: true}] = UserSessions.list(user)
  end

  test "sessions end after the idle time and the remember lifetime", %{conn: conn} do
    user = password_user()
    log_in(conn, user)
    [session] = UserSessions.list(user)
    {token, _} = UserSessions.create(user)
    assert {_user, _} = UserSessions.get_user(token)

    {:ok, _} = SiteSettings.update(%{"session_idle_hours" => "2"}, admin_fixture())
    session |> age(:last_seen_at, 3 * 3600) |> age(:inserted_at, 3 * 3600)
    assert [_live] = UserSessions.list(user)

    {:ok, _} = SiteSettings.update(%{"session_remember_days" => "1"}, admin_fixture())
    [live] = UserSessions.list(user)
    live |> age(:inserted_at, 2 * 86_400)
    assert UserSessions.list(user) == []
    assert UserSessions.get_user(token) == nil
    assert UserSessions.run_cleanup() == 2
  end

  test "logging out ends the session", %{conn: conn} do
    user = password_user()
    conn = log_in(conn, user)
    out = conn |> recycle() |> delete(~p"/auth/logout")
    assert UserSessions.list(user) == []
    assert out.resp_cookies["_firefly_remember"].max_age == 0
  end

  test "members see their devices and sign them out; their pages disconnect", %{conn: conn} do
    user = password_user()
    log_in(build_conn(), user)
    [other] = UserSessions.list(user)
    FireflyWeb.Endpoint.subscribe(UserSessions.live_socket_id(other))
    mine = log_in(conn, user)

    session =
      mine
      |> recycle()
      |> visit(~p"/settings/security")
      |> assert_has("#devices li", count: 2)
      |> assert_has("#devices .badge", text: "This browser")
      |> click_button("#device-#{other.id} button", "Sign out")
      |> assert_has("#devices li", count: 1)

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert [%{kind: "session.revoke"} | _] = Security.for_user(user)

    log_in(build_conn(), user)

    session
    |> visit(~p"/settings/security")
    |> click_button("Sign out of all other devices")
    |> assert_has("#devices li", count: 1)
  end

  test "a password reset signs out every session", %{conn: conn} do
    user = password_user()
    log_in(conn, user)
    log_in(build_conn(), user)
    {:ok, _} = Accounts.reset_user_password(user, %{password: "a brand new password"})
    assert UserSessions.list(user) == []
  end

  test "staff sign a member out everywhere, staff-logged", %{conn: conn} do
    user = password_user()
    admin = admin_fixture()
    log_in(build_conn(), user)

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/users/#{user.id}")
    |> click_button("Sign out everywhere")
    |> assert_has("#flash-info", text: "Signed them out of every device.")

    assert UserSessions.list(user) == []
    assert [%{action: "user.sign_out"}] = Repo.all(Firefly.Moderation.StaffAction)
    assert :ok = UserAdmin.sign_out_everywhere(user, admin)
  end
end
