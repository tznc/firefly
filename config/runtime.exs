import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

if System.get_env("FIREFLY_SERVER") do
  config :firefly_web, FireflyWeb.Endpoint, server: true
end

# The commit the code was built from (a Docker build argument) and the
# GitHub repository whose releases the version check follows (see
# Firefly.Upgrades).
config :firefly, Firefly.Upgrades,
  git_sha: System.get_env("FIREFLY_GIT_SHA"),
  repo: System.get_env("FIREFLY_UPDATE_REPO", "tznc/firefly")

# Reverse proxies (addresses or CIDR ranges, comma-separated) whose
# X-Forwarded-For header gives the client IP; see FireflyWeb.ClientIP.
config :firefly_web, FireflyWeb.ClientIP,
  trusted_proxies: String.split(System.get_env("FIREFLY_TRUSTED_PROXIES", ""), ",", trim: true)

# The secret AI providers' API keys are encrypted with at rest (see
# Firefly.AI.Encrypted); without it, a key derived from the secret key base.
if ai_key = System.get_env("FIREFLY_AI_ENCRYPTION_KEY") do
  config :firefly, Firefly.AI, encryption_key: ai_key
end

# Where uploads are stored: `local` (a directory, FIREFLY_UPLOAD_DIR) or
# `s3` (the FIREFLY_AWS_* bucket). See Firefly.Uploads.Storage.
if config_env() != :test do
  config :firefly, Firefly.Uploads,
    storage: if(System.get_env("FIREFLY_UPLOAD_STORAGE") == "s3", do: :s3, else: :local),
    local_dir: System.get_env("FIREFLY_UPLOAD_DIR", "uploads")

  # Backups (see Firefly.Backups): kept in FIREFLY_BACKUP_DIR, or in the
  # uploads' S3 bucket under a prefix. pg_dump/pg_restore come from
  # FIREFLY_PG_BIN_DIR, else the newest /usr/lib/postgresql/*/bin.
  config :firefly, Firefly.Backups,
    storage: if(System.get_env("FIREFLY_BACKUP_STORAGE") == "s3", do: :s3, else: :local),
    dir: System.get_env("FIREFLY_BACKUP_DIR", "backups"),
    s3_prefix: System.get_env("FIREFLY_BACKUP_S3_PREFIX", "backups/"),
    pg_bin_dir: System.get_env("FIREFLY_PG_BIN_DIR")

  # Social logins: each provider is enabled when its client id and secret
  # are set (see Firefly.Accounts.Auth).
  for {provider, config_key} <- [
        {"GITHUB", Ueberauth.Strategy.Github.OAuth},
        {"GOOGLE", Ueberauth.Strategy.Google.OAuth},
        {"DISCORD", Ueberauth.Strategy.Discord.OAuth},
        {"FACEBOOK", Ueberauth.Strategy.Facebook.OAuth},
        {"X", Firefly.Accounts.Auth.Strategies.X},
        {"SLACK", Firefly.Accounts.Auth.Strategies.Slack}
      ] do
    config :ueberauth, config_key,
      client_id: System.get_env("FIREFLY_#{provider}_CLIENT_ID"),
      client_secret: System.get_env("FIREFLY_#{provider}_CLIENT_SECRET")
  end

  # Apple's client secret is a JWT signed with the key Apple issued
  # (FIREFLY_APPLE_PRIVATE_KEY, the .p8 file's contents); see
  # Firefly.Accounts.Auth.AppleSecret.
  if System.get_env("FIREFLY_APPLE_PRIVATE_KEY") do
    config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
      client_id: System.get_env("FIREFLY_APPLE_CLIENT_ID"),
      client_secret: {Firefly.Accounts.Auth.AppleSecret, :client_secret}

    config :firefly, Firefly.Accounts.Auth.AppleSecret,
      team_id: System.get_env("FIREFLY_APPLE_TEAM_ID"),
      key_id: System.get_env("FIREFLY_APPLE_KEY_ID"),
      private_key: System.get_env("FIREFLY_APPLE_PRIVATE_KEY")
  end

  # The key and certificate (PEM) SAML login requests are signed with, when
  # the saml_sign_requests setting is on (see Firefly.Accounts.Auth.SAML).
  config :firefly, Firefly.Accounts.Auth.SAML,
    sp_key: System.get_env("FIREFLY_SAML_SP_KEY"),
    sp_cert: System.get_env("FIREFLY_SAML_SP_CERT")

  # Logging in with an LDAP directory (see Firefly.Accounts.Auth.LDAP): on
  # when a host and base DN are set.
  config :firefly, Firefly.Accounts.Auth.LDAP,
    host: System.get_env("FIREFLY_LDAP_HOST"),
    port:
      System.get_env("FIREFLY_LDAP_PORT") &&
        String.to_integer(System.get_env("FIREFLY_LDAP_PORT")),
    encryption: System.get_env("FIREFLY_LDAP_ENCRYPTION"),
    verify: System.get_env("FIREFLY_LDAP_VERIFY") not in ~w(false 0),
    ca_cert_file: System.get_env("FIREFLY_LDAP_CA_CERT_FILE"),
    bind_dn: System.get_env("FIREFLY_LDAP_BIND_DN"),
    bind_password: System.get_env("FIREFLY_LDAP_BIND_PASSWORD"),
    base_dn: System.get_env("FIREFLY_LDAP_BASE_DN"),
    user_filter: System.get_env("FIREFLY_LDAP_USER_FILTER"),
    uid_attribute: System.get_env("FIREFLY_LDAP_UID_ATTRIBUTE"),
    username_attribute: System.get_env("FIREFLY_LDAP_USERNAME_ATTRIBUTE"),
    email_attribute: System.get_env("FIREFLY_LDAP_EMAIL_ATTRIBUTE"),
    name_attribute: System.get_env("FIREFLY_LDAP_NAME_ATTRIBUTE"),
    group_base_dn: System.get_env("FIREFLY_LDAP_GROUP_BASE_DN"),
    group_filter: System.get_env("FIREFLY_LDAP_GROUP_FILTER"),
    group_name_attribute: System.get_env("FIREFLY_LDAP_GROUP_NAME_ATTRIBUTE"),
    name: System.get_env("FIREFLY_LDAP_NAME")

  # Single sign-on (see Firefly.Accounts.Auth.OIDC and
  # Firefly.Accounts.Auth.DiscourseConnect); FIREFLY_SSO_ONLY makes it the only
  # way to log in.
  config :firefly, Firefly.Accounts.Auth.OIDC,
    discovery_url: System.get_env("FIREFLY_OIDC_DISCOVERY_URL"),
    client_id: System.get_env("FIREFLY_OIDC_CLIENT_ID"),
    client_secret: System.get_env("FIREFLY_OIDC_CLIENT_SECRET"),
    scopes: System.get_env("FIREFLY_OIDC_SCOPES"),
    name: System.get_env("FIREFLY_OIDC_NAME")

  config :firefly, Firefly.Accounts.Auth.DiscourseConnect,
    url: System.get_env("FIREFLY_DISCOURSE_CONNECT_URL"),
    secret: System.get_env("FIREFLY_DISCOURSE_CONNECT_SECRET"),
    name: System.get_env("FIREFLY_DISCOURSE_CONNECT_NAME")

  config :firefly, Firefly.Accounts.Auth,
    sso_only: System.get_env("FIREFLY_SSO_ONLY") in ~w(true 1)

  # Browser push notifications (Firefly.Notifications.WebPush): off unless all three
  # are set. `mix firefly.gen.vapid_keys` makes a key pair.
  config :firefly, Firefly.Notifications.WebPush,
    public_key: System.get_env("FIREFLY_VAPID_PUBLIC_KEY"),
    private_key: System.get_env("FIREFLY_VAPID_PRIVATE_KEY"),
    subject: System.get_env("FIREFLY_VAPID_SUBJECT")

  # Configuration for AWS integration
  config :firefly, :aws,
    access_key_id: System.get_env("FIREFLY_AWS_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("FIREFLY_AWS_SECRET_ACCESS_KEY"),
    bucket: System.get_env("FIREFLY_AWS_S3_BUCKET"),
    region: System.get_env("FIREFLY_AWS_S3_REGION")
end

# Prometheus metrics (see FireflyWeb.Metrics): off unless a port of their own
# or a bearer token for /metrics on the main endpoint is set.
if port = System.get_env("FIREFLY_METRICS_PORT") do
  ip =
    case :inet.parse_address(String.to_charlist(System.get_env("FIREFLY_METRICS_IP", "0.0.0.0"))) do
      {:ok, ip} -> ip
      {:error, _} -> raise "FIREFLY_METRICS_IP is not an IP address"
    end

  config :firefly_web, FireflyWeb.Metrics, port: String.to_integer(port), ip: ip
end

if token = System.get_env("FIREFLY_METRICS_TOKEN") do
  config :firefly_web, FireflyWeb.Metrics, token: token
end

# OpenTelemetry (see FireflyWeb.OpenTelemetry), configured by the standard
# OTEL_* variables, which the SDK reads itself: nothing is exported without
# an OTLP endpoint. Metrics and logs over OTLP are experimental in the
# Erlang SDK, so they're opt-in on top.
otel_endpoint? = fn signal ->
  System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") != nil or
    System.get_env("OTEL_EXPORTER_OTLP_#{signal}_ENDPOINT") != nil
end

if config_env() != :test do
  traces? =
    otel_endpoint?.("TRACES") and System.get_env("OTEL_TRACES_EXPORTER", "otlp") != "none"

  metrics? =
    otel_endpoint?.("METRICS") and System.get_env("FIREFLY_OTEL_METRICS") in ~w(true 1)

  logs? = otel_endpoint?.("LOGS") and System.get_env("FIREFLY_OTEL_LOGS") in ~w(true 1)

  config :firefly_web, FireflyWeb.OpenTelemetry, traces: traces?, metrics: metrics?, logs: logs?

  if traces?, do: config(:opentelemetry, traces_exporter: :otlp)

  if metrics? do
    config :opentelemetry_experimental,
      readers: [
        %{
          module: :otel_metric_reader,
          config: %{
            exporter: {:otel_exporter_metrics_otlp, %{}},
            export_interval_ms:
              String.to_integer(System.get_env("OTEL_METRIC_EXPORT_INTERVAL", "60000"))
          }
        }
      ]
  end
end

# How long a shutting-down node fails readiness probes before the endpoint
# stops listening (see FireflyWeb.Draining).
if delay = System.get_env("FIREFLY_DRAIN_DELAY_MS") do
  config :firefly_web, FireflyWeb.Draining, delay: String.to_integer(delay)
end

if config_env() == :prod do
  database_url =
    System.get_env("FIREFLY_DATABASE_URL") ||
      raise """
      environment variable FIREFLY_DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("FIREFLY_DATABASE_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :firefly, Firefly.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("FIREFLY_DATABASE_POOL_SIZE", "10")),
    ssl: System.get_env("FIREFLY_DATABASE_SSL", "true") in ~w(true 1),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("FIREFLY_SECRET_KEY_BASE") ||
      raise """
      environment variable FIREFLY_SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Public domain the app is served on (also the default email domain)
  host = System.get_env("FIREFLY_DOMAIN", "firefly.tznc.dev")
  port = String.to_integer(System.get_env("FIREFLY_PORT", "4000"))

  # Listen on all IPv4 interfaces; set FIREFLY_IPV6=true to listen on IPv6 (and,
  # on most systems, IPv4 too), e.g. on Fly.io. IPv6-disabled hosts can't bind "::".
  ip =
    if System.get_env("FIREFLY_IPV6") in ~w(true 1),
      do: {0, 0, 0, 0, 0, 0, 0, 0},
      else: {0, 0, 0, 0}

  config :firefly_web, FireflyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: ip, port: port],
    secret_key_base: secret_key_base

  config :firefly, Firefly.Mailer,
    adapter: Bamboo.SendGridAdapter,
    api_key: System.get_env("FIREFLY_SENDGRID_API_KEY")

  config :firefly, :email,
    from: {"Firefly", System.get_env("FIREFLY_EMAIL_FROM", "noreply@#{host}")},
    reply_domain: System.get_env("FIREFLY_REPLY_EMAIL_DOMAIN", "reply.#{host}"),
    inbound_token: System.get_env("FIREFLY_INBOUND_EMAIL_TOKEN")
end
