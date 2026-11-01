defmodule FirestormWeb.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :firestorm_web

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_firestorm_web_key",
    signing_salt: "YhYEFZld",
    same_site: "Lax",
    http_only: true,
    secure: Mix.env() == :prod
  ]

  # Browser (Playwright) tests share the test's database transaction via
  # metadata in the user agent; see FirestormWeb.Web.LiveAcceptance.
  if Application.compile_env(:firestorm_web, :sql_sandbox) do
    plug(Phoenix.Ecto.SQL.Sandbox)
  end

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:user_agent, session: @session_options]],
    longpoll: [connect_info: [:user_agent, session: @session_options]]
  )

  # Origins are checked against the endpoint's host (see :check_origin).
  socket("/socket", FirestormWeb.Web.UserSocket,
    websocket: [timeout: 45_000],
    longpoll: false
  )

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phoenix.digest
  # when deploying your static files in production.
  # Kaffy's admin UI assets
  plug(Plug.Static, at: "/kaffy", from: :kaffy, gzip: false, only: ~w(assets))

  plug(
    Plug.Static,
    at: "/",
    from: :firestorm_web,
    gzip: false,
    only: FirestormWeb.Web.static_paths()
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
    plug(Phoenix.Ecto.CheckRepoStatus, otp_app: :firestorm_web)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(
    Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(Plug.Session, @session_options)

  plug(FirestormWeb.Web.Router)
end
