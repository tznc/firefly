defmodule FireflyWeb.Plugs.DatabaseAdmin do
  @moduledoc """
  Hides the raw records admin at `/staff/db` (see `FireflyWeb.Admin`)
  while the `enable_database_admin` site setting is off: its pages are a
  404, as if they didn't exist. Who may use it once it's on is
  `FireflyWeb.Plugs.RequireAdmin`'s call.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    if Firefly.SiteSettings.get("enable_database_admin"),
      do: conn,
      else: raise(Phoenix.Router.NoRouteError, conn: conn, router: FireflyWeb.Router)
  end
end
