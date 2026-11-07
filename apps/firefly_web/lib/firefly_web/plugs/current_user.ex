defmodule FireflyWeb.Plugs.CurrentUser do
  @moduledoc """
  Assigns `:current_user` (and `:impersonator`, the admin seeing the site
  as them, and `:user_session`) from the session, checked against the
  database on every request (see `FireflyWeb.Session`).
  """

  import Plug.Conn
  alias FireflyWeb.Session

  def init(options), do: options

  def call(%{assigns: %{current_user: _}} = conn, _opts), do: conn

  def call(conn, _opts) do
    {user, impersonator, session, conn} = Session.fetch(conn)

    conn
    |> assign(:current_user, user)
    |> assign(:impersonator, impersonator)
    |> assign(:user_session, session)
  end
end
