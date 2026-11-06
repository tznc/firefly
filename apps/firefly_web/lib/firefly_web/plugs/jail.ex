defmodule FireflyWeb.Plugs.Jail do
  @moduledoc """
  Turns away banned addresses (see `Firefly.Security.Jail`) with a minimal
  403 page, before the session or anything else runs.

  It sits in the endpoint right after `FireflyWeb.ClientIP`, so it judges
  the real client behind trusted proxies. The health and metrics endpoints
  are answered before it (monitoring keeps working), and sockets
  (`/live`, `/socket`) are dispatched before any plug: a banned client
  can't load a page to get the session and CSRF token a LiveView socket
  needs, and a member already connected keeps their page until they
  navigate.
  """
  @behaviour Plug

  import Plug.Conn

  alias Firefly.Security.Jail

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Jail.banned(conn.remote_ip) do
      nil -> conn
      ban -> refuse(conn, ban)
    end
  end

  # Sobelow: a fixed page.
  # sobelow_skip ["XSS.SendResp"]
  defp refuse(conn, ban) do
    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> retry_after(ban.until)
    |> send_resp(403, page())
    |> halt()
  end

  defp retry_after(conn, nil), do: conn

  defp retry_after(conn, until),
    do:
      put_resp_header(
        conn,
        "retry-after",
        to_string(max(DateTime.diff(until, DateTime.utc_now()), 1))
      )

  defp page do
    """
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8"><title>Access denied</title>
    <meta name="viewport" content="width=device-width, initial-scale=1"></head>
    <body><h1>Access denied</h1>
    <p>Too many failed or suspicious requests came from your network, so it's blocked for a while.</p>
    </body></html>
    """
  end
end
