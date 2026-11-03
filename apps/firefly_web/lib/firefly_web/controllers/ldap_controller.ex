defmodule FireflyWeb.LDAPController do
  @moduledoc """
  Directory logins (see `Firefly.Accounts.Auth.LDAP`): `request` (the
  login buttons' `/auth/ldap`) opens the form (`FireflyWeb.AuthLive.LDAP`),
  `create` checks the username and password, rate limited like password
  logins, and logs in, or, for a user already logged in, connects the
  directory account to them. A directory password counts as a password
  for two-factor authentication.
  """
  use FireflyWeb, :controller

  alias Firefly.RateLimit
  alias Firefly.Accounts.{Auth, User}
  alias Firefly.Accounts.Auth.LDAP
  alias FireflyWeb.{InviteController, Login}

  def request(conn, _params), do: redirect(conn, to: ~p"/login/ldap")

  def create(conn, %{"ldap" => %{"username" => username, "password" => password}})
      when is_binary(username) and is_binary(password) do
    with true <- LDAP.enabled?() || {:error, "Directory login isn't enabled."},
         :ok <- RateLimit.check_login(username, conn.remote_ip) do
      finish(conn, username, password)
    else
      {:error, :rate_limited} -> Login.fail(conn, ~p"/login/ldap", RateLimit.message())
      {:error, reason} -> Login.fail(conn, ~p"/login", reason)
    end
  end

  def create(conn, _params),
    do: Login.fail(conn, ~p"/login/ldap", LDAP.message(:invalid_credentials))

  defp finish(%{assigns: %{current_user: %User{} = user}} = conn, username, password) do
    label = LDAP.label()

    with {:ok, entry} <- LDAP.authenticate(username, password),
         {:ok, _identity} <- Auth.connect(user, LDAP.info(entry)) do
      LDAP.sync(user, entry)

      conn
      |> put_flash(:info, "#{label} account connected.")
      |> redirect(to: ~p"/settings/logins")
    else
      {:error, reason} when is_atom(reason) ->
        Login.fail(conn, ~p"/login/ldap", LDAP.message(reason))

      {:error, message} ->
        Login.fail(conn, ~p"/settings/logins", "That #{label} account #{message}.")
    end
  end

  defp finish(conn, username, password) do
    {invite, conn} = InviteController.take_invite(conn)

    case LDAP.login(username, password, invite) do
      {:ok, user} ->
        Login.complete(
          conn,
          user,
          ~p"/login/ldap",
          :password,
          InviteController.destination(invite)
        )

      {:error, reason} ->
        Login.fail(conn, ~p"/login/ldap", LDAP.message(reason))
    end
  end
end
