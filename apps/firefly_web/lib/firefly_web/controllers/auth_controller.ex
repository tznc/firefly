defmodule FireflyWeb.AuthController do
  @moduledoc """
  Handles the OAuth/identity callbacks from Ueberauth and logging out. The
  login pages themselves are LiveViews (`AuthLive.Login`, `AuthLive.Identity`).
  A provider's callback logs in (or registers; see `Firefly.Accounts.Auth`), or,
  for a user already logged in, connects that account to them.
  """
  use FireflyWeb, :controller

  alias Firefly.{Accounts, RateLimit}
  alias Firefly.Accounts.{Auth, User}
  alias FireflyWeb.{InviteController, Login}

  # Ueberauth redirects GET /auth/:provider for OAuth providers before this
  # action runs; we only get here for unknown providers, or when the
  # provider couldn't be reached (an OpenID Connect provider's discovery).
  def request(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn
    |> put_flash(:error, "That login provider can't be reached right now.")
    |> redirect(to: ~p"/login")
  end

  def request(conn, _params) do
    conn
    |> put_flash(:error, "Unknown login provider.")
    |> redirect(to: ~p"/login")
  end

  def delete(conn, _params) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_flash(:info, "You have been logged out!")
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_failure: _fails}} = conn, _params) do
    conn
    |> put_flash(:error, "Failed to authenticate.")
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: %{provider: :identity}}} = conn, params),
    do: identity_callback(conn, params)

  # Logged in already: connect the account (from the settings' Logins tab).
  def callback(%{assigns: %{ueberauth_auth: auth, current_user: %User{} = user}} = conn, _params) do
    info = Auth.from_ueberauth(auth)

    case Auth.connect(user, info) do
      {:ok, _identity} ->
        conn
        |> put_flash(:info, "#{Auth.label(info.provider)} account connected.")
        |> redirect(to: ~p"/settings/logins")

      {:error, message} ->
        conn
        |> put_flash(:error, "That #{Auth.label(info.provider)} account #{message}.")
        |> redirect(to: ~p"/settings/logins")
    end
  end

  # An invite the visitor came from (see `FireflyWeb.InviteController`)
  # lets the login create their account.
  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    {invite, conn} = InviteController.take_invite(conn)

    case Auth.login(Auth.from_ueberauth(auth), invite) do
      {:ok, user} ->
        Login.complete(conn, user, ~p"/login", :sso, InviteController.destination(invite))

      {:error, reason} ->
        Login.fail(conn, ~p"/login", reason)
    end
  end

  defp identity_callback(conn, params) do
    user_params = params["user"] || %{}

    with :ok <- RateLimit.check_login(user_params["username"], conn.remote_ip),
         {:ok, user} <-
           Accounts.authenticate_by_password(user_params["username"], user_params["password"]) do
      # Registering through an invite lands where the invite says.
      Login.complete(conn, user, ~p"/auth/identity", :password, params["return_to"] || "/")
    else
      {:error, :rate_limited} -> Login.fail(conn, ~p"/auth/identity", RateLimit.message())
      {:error, reason} -> Login.fail(conn, ~p"/auth/identity", reason)
    end
  end
end
