defmodule FirestormWeb.Web.Plugs.LoginProviders do
  @moduledoc """
  Sends `/auth/<provider>` (and its callback) back to the login page for
  login providers that aren't enabled (see `FirestormWeb.Auth`), before
  Ueberauth would send the browser to the provider with no credentials,
  and password logins (`/auth/identity`) when single sign-on is the only
  way in. Runs after the session and flash are fetched.
  """
  @behaviour Plug

  import Plug.Conn

  alias FirestormWeb.Auth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["auth", "identity" | _]} = conn, _opts) do
    if Auth.password_login?(), do: conn, else: refuse(conn, "Log in with single sign-on.")
  end

  def call(%Plug.Conn{path_info: ["auth", name | _]} = conn, _opts) do
    case Enum.find(Auth.providers(), &(to_string(&1) == name)) do
      nil ->
        conn

      provider ->
        if Auth.enabled?(provider),
          do: conn,
          else: refuse(conn, "#{Auth.label(provider)} login isn't enabled.")
    end
  end

  def call(conn, _opts), do: conn

  defp refuse(conn, message) do
    conn
    |> Phoenix.Controller.put_flash(:error, message)
    |> Phoenix.Controller.redirect(to: "/login")
    |> halt()
  end
end
