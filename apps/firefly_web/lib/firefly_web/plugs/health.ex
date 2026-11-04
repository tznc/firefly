defmodule FireflyWeb.Plugs.Health do
  @moduledoc """
  The probes monitoring and orchestrators call, answered at the top of the
  endpoint, before request ids, logging, sessions and the router: no
  CSRF, analytics, rate limits, locale or theme, and no log line per
  probe. Both answer JSON and need no authentication.

    * `GET /health` (liveness): `200` while the VM runs and the endpoint
      answers. No database call, so a database outage doesn't get the node
      restarted.
    * `GET /ready` (readiness): `200` when the node should get traffic,
      `503` naming the failing checks otherwise: the database answers,
      no migration is pending (see `Firefly.Health`) and the endpoint
      isn't draining (see `FireflyWeb.Draining`). Read-only mode, the
      plugin sandbox and the number of connected cluster nodes are
      reported but don't fail it.

  In production `force_ssl` skips these paths (see `config/prod.exs`), so
  probes over plain HTTP from inside the cluster get an answer instead of a
  redirect; there is no host check to pass.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method, path_info: ["health"]} = conn, _opts)
      when method in ~w(GET HEAD),
      do: respond(conn, 200, %{status: "ok"})

  def call(%Plug.Conn{method: method, path_info: ["ready"]} = conn, _opts)
      when method in ~w(GET HEAD) do
    checks =
      Map.put(Firefly.Health.readiness(), :draining, %{ok: not FireflyWeb.Draining.draining?()})

    if Firefly.Health.ready?(checks) do
      respond(conn, 200, %{status: "ready", checks: checks})
    else
      failing = for {name, %{ok: false}} <- checks, do: name
      respond(conn, 503, %{status: "unavailable", failing: Enum.sort(failing), checks: checks})
    end
  end

  def call(conn, _opts), do: conn

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode_to_iodata!(body))
    |> halt()
  end
end
