defmodule FireflyWeb.InviteController do
  @moduledoc """
  Signing up through an invite with a social or single sign-on login (see
  `Firefly.Accounts.Invites`): `login` keeps the invite's key in the
  session and sends the browser to the provider; the login callbacks
  (`FireflyWeb.AuthController`, `FireflyWeb.DiscourseConnectController`)
  take it back with `take_invite/1`.
  """
  use FireflyWeb, :controller

  alias Firefly.Accounts.{Auth, Invite, Invites}

  def login(conn, %{"key" => key, "provider" => provider}) do
    if Auth.enabled?(provider) and Invites.get_by_key(key) do
      conn
      |> put_session(:invite_key, key)
      |> redirect(to: ~p"/auth/#{provider}")
    else
      conn
      |> put_flash(:error, "That login isn't available.")
      |> redirect(to: ~p"/invites/#{key}")
    end
  end

  @doc "The invite kept in the session (or nil), and the conn without it."
  def take_invite(conn) do
    invite = Invites.get_by_key(get_session(conn, :invite_key))
    {invite, delete_session(conn, :invite_key)}
  end

  @doc "Where to go after logging in with `invite` (or without one)."
  def destination(%Invite{} = invite), do: Invites.destination(invite)
  def destination(nil), do: ~p"/"
end
