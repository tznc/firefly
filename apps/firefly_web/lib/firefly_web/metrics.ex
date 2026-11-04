defmodule FireflyWeb.Metrics do
  @moduledoc """
  Serves the metrics (see `FireflyWeb.Telemetry`) at `/metrics` in
  Prometheus' text format. Off unless configured (`config :firefly_web,
  FireflyWeb.Metrics`, from the environment):

    * `port` (`FIREFLY_METRICS_PORT`, preferred): a listener of its own on
      that port, apart from the public one, so the metrics stay inside
      the network. Binds `ip` (`FIREFLY_METRICS_IP`, default all IPv4
      interfaces).
    * `token` (`FIREFLY_METRICS_TOKEN`): also serves `/metrics` on the
      main endpoint, to requests with `Authorization: Bearer <token>`.
      With a port as well, the token is required there too.

  As a plug, it answers `GET /metrics` (and leaves anything else to the
  rest of the pipeline): the endpoint runs it before sessions and
  logging, as for the health probes.
  """
  @behaviour Plug

  import Plug.Conn

  @doc "Whether metrics are collected and served."
  @spec enabled?() :: boolean
  def enabled?, do: config()[:port] != nil or token() != nil

  @doc "The separate listener's child spec, when a port is set."
  def listener_specs do
    if port = config()[:port] do
      [
        {Bandit,
         plug: {__MODULE__, listener: true}, port: port, ip: config()[:ip] || {0, 0, 0, 0}}
      ]
    else
      []
    end
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: ["metrics"]} = conn, opts) do
    # On the main endpoint only with a token; on the listener, a token if set.
    token = token()

    cond do
      token == nil and not Keyword.get(opts, :listener, false) -> conn
      token != nil and not authorized?(conn, token) -> respond(conn, 401, "unauthorized\n")
      body = FireflyWeb.Telemetry.prometheus() -> respond(conn, 200, body)
      true -> respond(conn, 503, "metrics are off\n")
    end
  end

  def call(conn, opts) do
    if Keyword.get(opts, :listener, false), do: respond(conn, 404, "not found\n"), else: conn
  end

  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> given] -> Plug.Crypto.secure_compare(given, token)
      _ -> false
    end
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4", "utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, body)
    |> halt()
  end

  defp token do
    case config()[:token] do
      token when token in [nil, ""] -> nil
      token -> token
    end
  end

  defp config, do: Application.get_env(:firefly_web, __MODULE__, [])
end
