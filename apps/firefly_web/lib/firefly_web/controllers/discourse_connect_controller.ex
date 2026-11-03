defmodule FireflyWeb.DiscourseConnectController do
  @moduledoc """
  Logging in through a DiscourseConnect provider (see
  `Firefly.Accounts.Auth.DiscourseConnect`): `request` sends the browser there
  with a fresh nonce (also kept in this session), `callback` checks what
  comes back and logs in, or, for a user already logged in, connects the
  provider's account to them (from the settings' Logins tab).
  """
  use FireflyWeb, :controller

  alias Firefly.Accounts.{Auth, User}
  alias Firefly.Accounts.Auth.DiscourseConnect
  alias FireflyWeb.{InviteController, Login}

  def request(conn, _params) do
    {nonce, url} = DiscourseConnect.request(url(~p"/auth/discourse_connect/callback"))

    conn
    |> put_session(:discourse_connect_nonce, nonce)
    |> redirect(external: url)
  end

  def callback(conn, params) do
    nonce = get_session(conn, :discourse_connect_nonce)
    conn = delete_session(conn, :discourse_connect_nonce)

    case DiscourseConnect.verify(params["sso"], params["sig"], nonce) do
      {:ok, fields} -> finish(conn, fields)
      {:error, reason} -> Login.fail(conn, ~p"/login", DiscourseConnect.message(reason))
    end
  end

  defp finish(%{assigns: %{current_user: %User{} = user}} = conn, fields) do
    label = DiscourseConnect.label()

    case Auth.connect(user, DiscourseConnect.info(fields)) do
      {:ok, _identity} ->
        DiscourseConnect.sync(user, fields)

        conn
        |> put_flash(:info, "#{label} account connected.")
        |> redirect(to: ~p"/settings/logins")

      {:error, message} ->
        conn
        |> put_flash(:error, "That #{label} account #{message}.")
        |> redirect(to: ~p"/settings/logins")
    end
  end

  defp finish(conn, fields) do
    {invite, conn} = InviteController.take_invite(conn)

    case DiscourseConnect.login(fields, invite) do
      {:ok, user} ->
        Login.complete(conn, user, ~p"/login", :sso, InviteController.destination(invite))

      {:error, reason} ->
        Login.fail(conn, ~p"/login", reason)
    end
  end
end
