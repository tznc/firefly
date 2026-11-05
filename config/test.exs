import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
config :firefly, Firefly.Repo,
  username: System.get_env("FIREFLY_POSTGRES_USER", "postgres"),
  password: System.get_env("FIREFLY_POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("FIREFLY_POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("FIREFLY_POSTGRES_PORT", "5432")),
  database: "firestorm_web_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  ownership_timeout: 30_000

# The server runs during tests so Playwright end-to-end tests can drive it,
# on FIREFLY_TEST_PORT so several suites can run side by side.
config :firefly_web, FireflyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("FIREFLY_TEST_PORT", "4002"))],
  secret_key_base: "+r1xPk7Kz3gV0h7uN6pXqM1y2dJw8dW1H5rB0oYzq6c2Wc5yR6eLx9oQp3sZt4uV",
  server: true

# A fixed vault key (see Firefly.Vault), and the secret AI keys were
# encrypted with before the vault (the secret key base).
config :firefly, Firefly.Vault,
  keys: [Base.decode64!("5rDLCVAzTB1mo9lR8umkEKqthnWNPrQtZFkJRuQa6eI=")]

config :firefly,
       :legacy_ai_secret,
       "+r1xPk7Kz3gV0h7uN6pXqM1y2dJw8dW1H5rB0oYzq6c2Wc5yR6eLx9oQp3sZt4uV"

# Let browser tests share the test's database transaction
config :firefly_web, sql_sandbox: true

# Spans are exported nowhere; FireflyWeb.OpenTelemetryTest collects them
# itself, with the instrumentation attached for its own tests only.
config :opentelemetry, traces_exporter: :none

# A metric reader that exports only when flushed, to the process registered
# as :firefly_otel_metrics_test (see FireflyWeb.OpenTelemetryTest).
config :opentelemetry_experimental,
  readers: [
    %{
      module: :otel_metric_reader,
      config: %{exporter: {:otel_metric_exporter_pid, {:otel_metric, :firefly_otel_metrics_test}}}
    }
  ]

config :phoenix_test,
  otp_app: :firefly_web,
  endpoint: FireflyWeb.Endpoint,
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

# Tests run due thread timers and reminders themselves, inside their sandbox transaction.

# Analytics are written when tests call Firefly.Analytics.flush/0.
config :firefly, Firefly.Analytics, flush_interval: :manual

# Reports read each test's own data: no cache shared between tests.
config :firefly, Firefly.Reports, cache: false

config :firefly, Firefly.Backups, dir: Path.join(System.tmp_dir!(), "firefly-test-backups")

# Each test reads its own (transactional) site settings: no shared cache.
config :firefly, site_settings_cache: false

config :firefly, Firefly.Mailer, adapter: Swoosh.Adapters.Test

# Jobs are only inserted; tests run them with Oban.Testing (perform_job/3,
# drain_queue/2).
config :firefly, Oban, testing: :manual
config :firefly_web, :jobs_dashboard_oban, FireflyWeb.JobsDashboardOban

config :firefly, :email,
  from: {"Firefly", "noreply@firefly.tznc.dev"},
  reply_domain: "reply.firefly.tznc.dev",
  inbound_token: "test-inbound-token"

config :bcrypt_elixir, :log_rounds, 4

config :firefly, :aws,
  access_key_id: "test-access-key-id",
  secret_access_key: "test-secret-access-key",
  bucket: "firestorm-test",
  region: "us-east-1"

# Uploads go to a scratch directory, emptied by test_helper.exs.
config :firefly, Firefly.Uploads,
  storage: :local,
  local_dir: Path.join(System.tmp_dir!(), "firefly-test-uploads")

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view, enable_expensive_runtime_checks: true

# Generous limits so ordinary tests never trip them; rate limit tests lower
# them explicitly.
config :firefly, Firefly.RateLimit,
  limits: [
    login: {1_000, 60_000},
    login_ip: {10_000, 60_000},
    register: {1_000, 60_000},
    post: {1_000, 60_000},
    upload: {1_000, 60_000},
    like: {1_000, 60_000},
    message: {1_000, 60_000},
    chat: {1_000, 60_000},
    export: {1_000, 60_000},
    email: {1_000, 60_000},
    two_factor: {1_000, 60_000},
    magic_link: {1_000, 60_000},
    password_reset: {1_000, 60_000},
    search: {1_000, 60_000},
    ai: {1_000, 60_000},
    mcp: {1_000, 60_000},
    flag: {1_000, 60_000},
    invite: {1_000, 60_000},
    plugin_notify: {1_000, 60_000},
    plugin_call: {1_000, 60_000},
    plugin_api: {1_000, 60_000},
    plugin_storage: {1_000, 60_000}
  ]

# Each test sees its own (transactional) plugins: no shared cache.
config :firefly, :plugins_cache, false

# AI providers are faked by local servers (see Firefly.AI.FakeProvider):
# retries don't wait.
config :firefly, Firefly.AI, retry_base_ms: 0, async: false
# Akismet is faked by a local server too (see Firefly.FakeAkismet).
config :firefly, Firefly.Moderation.Akismet, async: false

# Link previews aren't fetched, except by the tests of them.
config :firefly, Firefly.Rendering.LinkPreviews, enabled: false

# Pushes are sent in the test's process (VAPID keys are set by the tests
# that need them).
config :firefly, Firefly.Notifications.WebPush, async: false

# Every social login is enabled, with made-up credentials (tests fake the
# providers' callbacks).
for config_key <- [
      Ueberauth.Strategy.Github.OAuth,
      Ueberauth.Strategy.Google.OAuth,
      Ueberauth.Strategy.Discord.OAuth,
      Ueberauth.Strategy.Apple.OAuth,
      Ueberauth.Strategy.Facebook.OAuth,
      Firefly.Accounts.Auth.Strategies.X,
      Firefly.Accounts.Auth.Strategies.Slack
    ] do
  config :ueberauth, config_key, client_id: "test-client", client_secret: "test-secret"
end
