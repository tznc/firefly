defmodule FireflyWeb.Plugs.LoginProviders do
  @moduledoc """
  Sends `/auth/<provider>` (and its callback) back to the login page for
  login providers that aren't enabled (see `Firefly.Accounts.Auth`), before
  Ueberauth would send the browser to the provider with no credentials,
  and password logins (`/auth/identity`) when single sign-on is the only
  way in, or the directory's form when LDAP replaces local passwords. Runs after the session and flash are fetched.
  """
  @behaviour Plug

  import Plug.Conn

  alias Firefly.Accounts.Auth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["auth", "identity" | _]} = conn, _opts) do
    cond do
      Auth.password_login?() ->
        conn

      Auth.ldap_replaces_password?() ->
        conn |> Phoenix.Controller.redirect(to: "/login/ldap") |> halt()

      true ->
        refuse(conn, "Log in with single sign-on.")
    end
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
