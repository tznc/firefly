defmodule FirestormWeb.Web.Plugs.LoginProviders do
  @moduledoc """
  Sends `/auth/<provider>` (and its callback) back to the login page for
  social login providers that aren't enabled (see `FirestormWeb.Auth`),
  before Ueberauth would send the browser to the provider with no
  credentials. Runs after the session and flash are fetched.
  """
  @behaviour Plug

  import Plug.Conn

  alias FirestormWeb.Auth

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["auth", name | _]} = conn, _opts) do
    case Enum.find(Auth.providers(), &(to_string(&1) == name)) do
      nil ->
        conn

      provider ->
        if Auth.enabled?(provider),
          do: conn,
          else:
            conn
            |> Phoenix.Controller.put_flash(
              :error,
              "#{Auth.label(provider)} login isn't enabled."
            )
            |> Phoenix.Controller.redirect(to: "/login")
            |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
