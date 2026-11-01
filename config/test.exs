import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
config :firestorm_web, FirestormWeb.Repo,
  username: System.get_env("FIREFLY_POSTGRES_USER", "postgres"),
  password: System.get_env("FIREFLY_POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("FIREFLY_POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("FIREFLY_POSTGRES_PORT", "5432")),
  database: "firestorm_web_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  ownership_timeout: 30_000

# The server runs during tests so Playwright end-to-end tests can drive it.
config :firestorm_web, FirestormWeb.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "+r1xPk7Kz3gV0h7uN6pXqM1y2dJw8dW1H5rB0oYzq6c2Wc5yR6eLx9oQp3sZt4uV",
  server: true

# Let browser tests share the test's database transaction
config :firestorm_web, sql_sandbox: true

config :phoenix_test,
  otp_app: :firestorm_web,
  endpoint: FirestormWeb.Web.Endpoint,
  playwright:
    [
      browser: :chromium,
      assets_dir: "assets",
      ecto_sandbox_stop_owner_delay: 100,
      # How long assertions wait for the page. The 2s default flaked on busy
      # CI runners (e.g. the redirect after logging in); passing assertions
      # don't wait any longer.
      timeout: to_timeout(second: 10),
      trace: System.get_env("FIREFLY_PW_TRACE", "false") in ~w(t true),
      screenshot: System.get_env("FIREFLY_PW_SCREENSHOT", "false") in ~w(t true)
    ] ++
      if(path = System.get_env("FIREFLY_CHROMIUM_PATH"),
        # Use an already-installed Chromium instead of Playwright's own.
        do: [executable_path: path],
        else: []
      )

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Start notification server in app start
config :firestorm_web, notifications_enabled: false

# Each test reads its own (transactional) site settings: no shared cache.
config :firestorm_web, site_settings_cache: false

config :firestorm_web, FirestormWeb.Mailer, adapter: Bamboo.TestAdapter

config :firestorm_web, :email,
  from: {"Firefly", "noreply@firefly.tznc.dev"},
  reply_domain: "reply.firefly.tznc.dev",
  inbound_token: "test-inbound-token"

config :bamboo, :refute_timeout, 10

config :bcrypt_elixir, :log_rounds, 4

config :firestorm_web, :aws,
  access_key_id: "test-access-key-id",
  secret_access_key: "test-secret-access-key",
  bucket: "firestorm-test",
  region: "us-east-1"

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view, enable_expensive_runtime_checks: true

# Generous limits so ordinary tests never trip them; rate limit tests lower
# them explicitly.
config :firestorm_web, FirestormWeb.RateLimit,
  limits: [
    login: {1_000, 60_000},
    login_ip: {10_000, 60_000},
    register: {1_000, 60_000},
    post: {1_000, 60_000},
    upload: {1_000, 60_000},
    like: {1_000, 60_000},
    message: {1_000, 60_000},
    export: {1_000, 60_000},
    email: {1_000, 60_000},
    password_reset: {1_000, 60_000},
    search: {1_000, 60_000}
  ]
