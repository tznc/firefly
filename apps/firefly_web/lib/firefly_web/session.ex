defmodule FireflyWeb.Session do
  @moduledoc """
  Who's logged in, from the session cookie: it holds only a session token
  (`"session_token"`, see `Firefly.Accounts.UserSessions`), checked against
  the database on every request and LiveView mount, so a session signed out
  elsewhere, expired, or of a deleted or suspended account resolves to
  nobody. "Keep me logged in" also sets a signed `_firefly_remember`
  cookie with the token, which restores the session after the browser's
  session cookie is gone.

  An admin impersonating a member keeps their own token, with the member's
  id in `"impersonate_id"` (see `FireflyWeb.StaffController`): the member
  is the current user while the admin's session is live and they're still
  an admin.
  """

  import Plug.Conn

  alias Firefly.Accounts
  alias Firefly.Accounts.{User, UserSessions}

  @remember_cookie "_firefly_remember"

  @doc "The current user for a conn, from its assigns or its session."
  def current_user(%Plug.Conn{assigns: %{current_user: user}}), do: user
  def current_user(%Plug.Conn{} = conn), do: conn |> fetch() |> elem(0)

  @doc """
  Resolves the conn's login: `{user, impersonator, session, conn}` (nils
  for nobody). A live "keep me logged in" cookie with no session cookie
  starts the session again; a dead one is deleted.
  """
  def fetch(%Plug.Conn{} = conn) do
    conn = fetch_cookies(conn, signed: [@remember_cookie])

    {token, conn} =
      case get_session(conn, :session_token) do
        nil -> {conn.cookies[@remember_cookie], conn}
        token -> {token, conn}
      end

    case token && UserSessions.get_user(token, ip: conn.remote_ip) do
      {owner, session} ->
        conn =
          if get_session(conn, :session_token),
            do: conn,
            else: put_token(conn, token, session)

        {user, impersonator} = impersonation(owner, get_session(conn, :impersonate_id))
        {user, impersonator, session, conn}

      _nobody ->
        conn =
          if get_session(conn, :session_token),
            do: delete_session(conn, :session_token),
            else: conn

        {nil, nil, nil, forget(conn)}
    end
  end

  @doc """
  The login of a LiveView's `session` (the cookie's contents):
  `{user, impersonator}`. `ip` is the client's, to note where the session
  was last seen.
  """
  def from_live_session(session, ip \\ nil) do
    case UserSessions.get_user(session["session_token"], ip: ip) do
      {owner, _session} -> impersonation(owner, session["impersonate_id"])
      nil -> {nil, nil}
    end
  end

  defp impersonation(owner, nil), do: {owner, nil}

  defp impersonation(owner, id) do
    with true <- Accounts.admin?(owner),
         %User{deleted_at: nil} = user <- Accounts.get_user(id),
         false <- User.suspended?(user) do
      {user, owner}
    else
      _ -> {owner, nil}
    end
  end

  @doc """
  Starts a session for `user` (see `FireflyWeb.Login`): a renewed session
  cookie with its token and socket id, and with `remember` the "keep me
  logged in" cookie for `session_remember_days`.
  """
  def start(conn, %User{} = user, remember) do
    {token, session} =
      UserSessions.create(user,
        remember: remember,
        ip: conn.remote_ip,
        user_agent: conn |> get_req_header("user-agent") |> List.first()
      )

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_token(token, session)
    |> remember(token, remember)
  end

  defp put_token(conn, token, session) do
    conn
    |> put_session(:session_token, token)
    |> put_session(:live_socket_id, UserSessions.live_socket_id(session))
  end

  defp remember(conn, _token, false), do: conn

  defp remember(conn, token, true) do
    put_resp_cookie(conn, @remember_cookie, token,
      sign: true,
      max_age: Firefly.SiteSettings.get("session_remember_days") * 86_400,
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https
    )
  end

  @doc "Ends the conn's session (logging out): its row, and both cookies."
  def stop(conn) do
    {_user, _impersonator, session, conn} = fetch(conn)
    if session, do: UserSessions.revoke(session, %{reason: "logged out"})

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> forget()
  end

  defp forget(conn) do
    if Map.has_key?(conn.req_cookies, @remember_cookie),
      do: delete_resp_cookie(conn, @remember_cookie),
      else: conn
  end

  @doc """
  Makes every open page of `user` pick up a change to their account (see
  `Firefly.Accounts.UserSessions.reload_pages/1` and `FireflyWeb.UserAuth`).
  """
  defdelegate reload_pages(user), to: UserSessions

  def logged_in?(conn), do: !!current_user(conn)

  def admin?(conn) do
    case current_user(conn) do
      nil -> false
      user -> Accounts.admin?(user)
    end
  end
end
