defmodule FireflyWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :firefly_web

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  # The key and salt predate the umbrella: keep them, or every session ends.
  @session_options [
    store: :cookie,
    key: "_firestorm_web_key",
    signing_salt: "YhYEFZld",
    same_site: "Lax",
    http_only: true,
    secure: Mix.env() == :prod
  ]

  # Browser (Playwright) tests share the test's database transaction via
  # metadata in the user agent; see FireflyWeb.LiveAcceptance.
  if Application.compile_env(:firefly_web, :sql_sandbox) do
    plug(Phoenix.Ecto.SQL.Sandbox)
  end

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:user_agent, :peer_data, :x_headers, session: @session_options]],
    longpoll: [connect_info: [:user_agent, :peer_data, :x_headers, session: @session_options]]
  )

  # Origins are checked against the endpoint's host (see :check_origin).
  socket("/socket", FireflyWeb.UserSocket,
    websocket: [timeout: 45_000],
    longpoll: false
  )

  # Liveness and readiness probes (/health, /ready) and metrics, before
  # anything that would log, track or touch the session.
  plug(FireflyWeb.Plugs.Health)
  # Prometheus metrics at /metrics, with FIREFLY_METRICS_TOKEN (see FireflyWeb.Metrics).
  plug(FireflyWeb.Metrics)

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phoenix.digest
  # when deploying your static files in production.
  # The Kaffy database admin's own assets (see FireflyWeb.Admin).
  plug(Plug.Static, at: "/kaffy", from: :kaffy, gzip: false, only: ~w(assets))

  plug(
    Plug.Static,
    at: "/",
    from: :firefly_web,
    gzip: false,
    only: FireflyWeb.static_paths()
  )

  # The standard emoji list, which the domain owns too (see Firefly.Rendering.Emoji).
  plug(Plug.Static, at: "/", from: :firefly, gzip: false, only: ~w(vendor))

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
    plug(Phoenix.Ecto.CheckRepoStatus, otp_app: :firefly_web)
  end

  # The client's IP behind trusted proxies, for per-IP rate limits.
  plug(FireflyWeb.ClientIP)
  # Banned addresses go no further (see Firefly.Security.Jail), and
  # scanners' requests count towards a ban.
  plug(FireflyWeb.Plugs.Jail)
  plug(FireflyWeb.Plugs.Probes)

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(
    Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  # Postgres can't store a NUL character: none gets past here.
  plug(FireflyWeb.Plugs.StripNul)

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(Plug.Session, @session_options)

  plug(FireflyWeb.Router)
end
