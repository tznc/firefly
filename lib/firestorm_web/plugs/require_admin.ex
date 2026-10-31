defmodule FirestormWeb.Web.Plugs.RequireAdmin do
  @moduledoc """
  A `Plug` that redirects to the home page unless the current user is an admin.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import FirestormWeb.Web.Session, only: [admin?: 1]

  def init(options), do: options

  def call(conn, _opts) do
    if admin?(conn) do
      conn
    else
      conn
      |> put_flash(:error, "You must be an administrator to access this page.")
      |> redirect(to: "/")
      |> halt()
    end
  end
end
