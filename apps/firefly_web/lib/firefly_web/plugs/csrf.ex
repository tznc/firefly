defmodule FireflyWeb.Plugs.CSRF do
  @moduledoc """
  `Plug.CSRFProtection` (what `protect_from_forgery` runs), with each
  rejected request reported to the jail as a `csrf` signal (see
  `Firefly.Security.Jail`) before the error is raised as usual (a 403).
  """
  @behaviour Plug

  @impl true
  def init(opts), do: Plug.CSRFProtection.init(opts)

  @impl true
  def call(conn, opts) do
    Plug.CSRFProtection.call(conn, opts)
  rescue
    error in Plug.CSRFProtection.InvalidCSRFTokenError ->
      Firefly.Security.Jail.signal(conn.remote_ip, "csrf", %{
        path: String.slice(conn.request_path, 0, 100)
      })

      reraise error, __STACKTRACE__
  end
end
