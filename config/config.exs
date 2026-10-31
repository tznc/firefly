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

# Path prefixes from which to serve web assets
config :firestorm_web,
  js_path_prefix: "",
  css_path_prefix: "",
  image_path_prefix: ""

# Configures the endpoint
config :firestorm_web, FirestormWeb.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FirestormWeb.Web.ErrorView, json: FirestormWeb.Web.ErrorView],
    layout: false
  ],
  pubsub_server: FirestormWeb.PubSub

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

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  firestorm_web: [
    args:
      ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure dart_sass (the version is required)
config :dart_sass,
  version: "1.107.1",
  default: [
    args:
      ~w(--load-path=node_modules --silence-deprecation=import --silence-deprecation=global-builtin css/app.scss ../priv/static/css/app.css),
    cd: Path.expand("../assets", __DIR__)
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
