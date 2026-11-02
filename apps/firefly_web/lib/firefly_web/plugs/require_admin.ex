defmodule FireflyWeb.Plugs.RequireAdmin do
  @moduledoc """
  A `Plug` that redirects to the home page unless the current user is an
  admin, and to their security settings if they must set up two-factor
  authentication first (see `Firefly.TwoFactor.must_enroll?/1`).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import FireflyWeb.Session, only: [admin?: 1]

  def init(options), do: options

  def call(conn, _opts) do
    cond do
      not admin?(conn) ->
        refuse(conn, "You must be an administrator to access this page.", "/")

      Firefly.TwoFactor.must_enroll?(conn.assigns.current_user) ->
        refuse(conn, "Set up two-factor authentication to go on.", "/settings/security")

      true ->
        conn
    end
  end

  defp refuse(conn, message, path) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: path)
    |> halt()
  end
end
