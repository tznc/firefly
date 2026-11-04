# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
import Config

# General application configuration
config :firefly,
  ecto_repos: [Firefly.Repo],
  generators: [timestamp_type: :naive_datetime_usec]

config :firefly_web,
  ecto_repos: [Firefly.Repo],
  generators: [context_app: :firefly, timestamp_type: :naive_datetime_usec]

# The interface's languages (see FireflyWeb.Locale). Translations live in
# apps/firefly_web/priv/gettext.
config :firefly_web, FireflyWeb.Gettext,
  default_locale: "en",
  locales: ~w(en es fr de pt_BR ja zh_CN ar)

# Ecto 2 stored microsecond timestamps; keep doing so for new migrations.
config :firefly, Firefly.Repo,
  migration_timestamps: [type: :naive_datetime_usec],
  # Ecto's types and pgvector's (see Firefly.PostgrexTypes).
  types: Firefly.PostgrexTypes

# The web interface the domain links to and broadcasts through (see
# Firefly.Endpoint): the domain never references it at compile time.
config :firefly, Firefly.Endpoint, impl: FireflyWeb.Endpoint

# Start notification server in app start
config :firefly, notifications_enabled: true

# Configures the endpoint
config :firefly_web, FireflyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FireflyWeb.ErrorHTML, json: FireflyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Firefly.PubSub,
  live_view: [signing_salt: "kQ4vL1xZ8fPm3Rt7"]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  # The trace a log line belongs to (set by OpenTelemetry's API in spans).
  metadata: [:request_id, :otel_trace_id, :otel_span_id]

# OpenTelemetry exports nothing unless config/runtime.exs finds an OTLP
# endpoint (see FireflyWeb.OpenTelemetry).
config :opentelemetry, traces_exporter: :none

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configures Ueberauth for OAuth stuff
# Every social login is listed; each only works once its client id and
# secret are set (see config/runtime.exs and Firefly.Accounts.Auth).
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: ""]},
    google: {Ueberauth.Strategy.Google, [default_scope: "openid email profile"]},
    discord: {Ueberauth.Strategy.Discord, [default_scope: "identify email"]},
    # No scopes: Apple then answers with a GET (scopes need a cross-site
    # form POST, which carries no session or CSRF token). It gives no email.
    apple: {Ueberauth.Strategy.Apple, [default_scope: ""]},
    x: {Firefly.Accounts.Auth.Strategies.X, []},
    facebook: {Ueberauth.Strategy.Facebook, []},
    slack: {Firefly.Accounts.Auth.Strategies.Slack, []},
    # Single sign-on with the configured OpenID Connect provider.
    oidc: {Firefly.Accounts.Auth.Strategies.OIDC, []},
    identity: {Ueberauth.Strategy.Identity, [callback_methods: ["POST"]]}
  ]

config :firefly, Firefly.Mailer, adapter: Bamboo.LocalAdapter

# Outbound email and reply-by-email. `inbound_token` is the shared secret the
# SendGrid Inbound Parse webhook must send (reply-by-email is off without it).
config :firefly, :email,
  from: {"Firefly", "noreply@firefly.tznc.dev"},
  reply_domain: "reply.firefly.tznc.dev",
  inbound_token: nil

# Kaffy: the optional raw-records admin at /staff/db, for admins, while the
# `enable_database_admin` site setting is on (see FireflyWeb.Admin).
config :kaffy,
  otp_app: :firefly_web,
  ecto_repo: Firefly.Repo,
  router: FireflyWeb.Router,
  admin_title: "Firefly database",
  admin_footer: {:safe, ~s(Firefly by <a href="https://tznc.dev">tznc.dev</a>)},
  admin_logo: [url: "/images/firefly-icon.svg", style: "max-height: 40px"],
  admin_logo_mini: "/images/firefly-icon.svg",
  home_page: [schema: [:content, :category]],
  resources: &FireflyWeb.Admin.resources/1,
  extensions: [FireflyWeb.Admin.Theme]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  firefly_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/firefly_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  firefly_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/firefly_web", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # The Firefly skin for the Kaffy database admin
  admin: [
    args: ~w(
      --input=assets/css/admin.css
      --output=priv/static/assets/css/admin.css
    ),
    cd: Path.expand("../apps/firefly_web", __DIR__)
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
