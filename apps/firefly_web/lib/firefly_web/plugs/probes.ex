defmodule FireflyWeb.Plugs.Probes do
  @moduledoc """
  Scanning signals for the jail (see `Firefly.Security.Jail`): a request for
  a path only exploit scanners ask for (`/wp-login.php`, `/.env`, `/.git/`,
  `/phpmyadmin`...) is answered 404 at once and counts heavily
  (`exploit_probe`); any other response that ends up a 404 counts a little
  (`not_found`). Other PHP paths aren't probes: imported forums' old URLs
  (`/viewtopic.php`) redirect (see `Firefly.Import`).
  """
  @behaviour Plug

  import Plug.Conn

  alias Firefly.Security.Jail

  # Firefly serves none of these: nobody but a scanner asks for them.
  @probe ~r{
    \.(env|ini|bak|sql|swp)$
    | ^/(wp-admin|wp-content|wp-includes|wp-login|wp-config|xmlrpc|phpmyadmin|pma|cgi-bin
         |vendor/phpunit|\.git|\.svn|\.hg|\.env|\.aws|\.ssh|\.DS_Store|actuator
         |server-status|boaform|HNAP1|owa)(/|$|\.)
  }xi

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Regex.match?(@probe, conn.request_path) do
      Jail.signal(conn.remote_ip, "exploit_probe", %{
        path: String.slice(conn.request_path, 0, 100)
      })

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not found")
      |> halt()
    else
      register_before_send(conn, &not_found/1)
    end
  end

  defp not_found(%{status: 404} = conn) do
    Jail.signal(conn.remote_ip, "not_found")
    conn
  end

  defp not_found(conn), do: conn

  @doc "Whether `path` is one only exploit scanners request."
  def probe?(path), do: Regex.match?(@probe, path)
end
