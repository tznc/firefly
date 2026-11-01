# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
import Config

# General application configuration
config :firestorm_web,
  ecto_repos: [FirestormWeb.Repo],
  generators: [timestamp_type: :naive_datetime_usec]

# Ecto 2 stored microsecond timestamps; keep doing so for new migrations.
config :firestorm_web, FirestormWeb.Repo, migration_timestamps: [type: :naive_datetime_usec]

# Start notification server in app start
config :firestorm_web, notifications_enabled: true

# Configures the endpoint
config :firestorm_web, FirestormWeb.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FirestormWeb.Web.ErrorHTML, json: FirestormWeb.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: FirestormWeb.PubSub,
  live_view: [signing_salt: "kQ4vL1xZ8fPm3Rt7"]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configures Ueberauth for OAuth stuff
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: ""]},
    identity: {Ueberauth.Strategy.Identity, [callback_methods: ["POST"]]}
  ]

config :firestorm_web, FirestormWeb.Mailer, adapter: Bamboo.LocalAdapter

# Kaffy admin UI, mounted at /admin for users with the "admin" role
config :kaffy,
  otp_app: :firestorm_web,
  ecto_repo: FirestormWeb.Repo,
  router: FirestormWeb.Web.Router,
  admin_title: "Firefly Admin",
  admin_logo: [url: "/images/firefly-icon.svg", style: "max-height: 40px"],
  admin_logo_mini: "/images/firefly-icon.svg",
  home_page: [kaffy: :dashboard],
  resources: &FirestormWeb.Admin.resources/1

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  firestorm_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  firestorm_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
