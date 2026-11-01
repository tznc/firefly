import Config

# Configure your database
config :firestorm_web, FirestormWeb.Repo,
  username: System.get_env("FIREFLY_POSTGRES_USER", "postgres"),
  password: System.get_env("FIREFLY_POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("FIREFLY_POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("FIREFLY_POSTGRES_PORT", "5432")),
  database: "firestorm_web_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# For development, we disable any cache and enable
# debugging and code reloading.
config :firestorm_web, FirestormWeb.Web.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("FIREFLY_PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "Q1bBtoEs8F2+MsssVU8zHXvhJBVFDI/4EFEINldDXBlVsBkNr30gi4WIGNwds+YO",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:firestorm_web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:firestorm_web, ~w(--watch)]},
    tailwind_admin: {Tailwind, :install_and_run, [:admin, ~w(--watch)]}
  ]

# Watch static and templates for browser reloading.
config :firestorm_web, FirestormWeb.Web.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/firestorm_web/web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :firestorm_web, dev_routes: true
