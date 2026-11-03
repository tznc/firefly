defmodule FireflyWeb.Plugs.ReadOnly do
  @moduledoc """
  Refuses API writes (anything but `GET`, `HEAD` and `OPTIONS`) with `503`
  while the site is read-only (see `Firefly.Backups`).
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ~w(GET HEAD OPTIONS),
    do: conn

  def call(conn, _opts) do
    if Firefly.Backups.read_only?() do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("retry-after", "300")
      |> send_resp(503, Jason.encode!(%{error: "The forum is read-only for maintenance."}))
      |> halt()
    else
      conn
    end
  end
end
