defmodule FireflyWeb.Plugs.ReadOnly do
  @moduledoc """
  Refuses API writes (anything but `GET`, `HEAD` and `OPTIONS`) with `503`
  while the site is read-only (see `Firefly.Backups`).
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ~w(GET HEAD OPTIONS),
    do: conn

  def call(conn, _opts) do
    if Firefly.Backups.read_only?() do
      conn
      |> Plug.Conn.put_resp_header("retry-after", "300")
      |> FireflyWeb.Api.Problem.send(503, "The forum is read-only for maintenance.")
    else
      conn
    end
  end
end
