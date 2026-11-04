defmodule FireflyWeb.Plugs.AkismetClient do
  @moduledoc """
  Records the request's client (IP address, user agent, referrer) for the
  Akismet checks of what this request posts (see
  `Firefly.Moderation.Akismet.put_client/1`). LiveViews do the same in
  `FireflyWeb.UserAuth`, from their connection.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Firefly.Moderation.Akismet.put_client(%{
      ip: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: conn |> Plug.Conn.get_req_header("user-agent") |> List.first(),
      referrer: conn |> Plug.Conn.get_req_header("referer") |> List.first()
    })

    conn
  end
end
