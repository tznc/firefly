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

# The jail never bans the trusted proxies (see Firefly.Security.Jail).
config :firefly, Firefly.Security.Jail,
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

  # Virus scanning of uploads with a clamd daemon, when FIREFLY_CLAMAV_HOST
  # is set (see Firefly.Uploads.Scanner).
  config :firefly, Firefly.Uploads.Scanner,
    host: System.get_env("FIREFLY_CLAMAV_HOST"),
    port: String.to_integer(System.get_env("FIREFLY_CLAMAV_PORT", "3310"))

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

# Outbound email (see Firefly.Mailer): FIREFLY_MAIL_ADAPTER picks the adapter,
# each with its own variables. Production refuses to start without one;
# development keeps mail in memory, the tests in the test adapter.
mail_adapter = System.get_env("FIREFLY_MAIL_ADAPTER")

if config_env() != :test and mail_adapter do
  required = fn name ->
    System.get_env(name) ||
      raise "environment variable #{name} is missing (needed with FIREFLY_MAIL_ADAPTER=#{mail_adapter})"
  end

  choice = fn name, default, choices ->
    value = System.get_env(name, default)

    Map.get(choices, value) ||
      raise "#{name}=#{value} isn't one of #{Enum.join(Map.keys(choices), ", ")}"
  end

  mail =
    case mail_adapter do
      "smtp" ->
        relay = required.("FIREFLY_SMTP_RELAY")
        ssl? = System.get_env("FIREFLY_SMTP_SSL") in ~w(true 1)

        # Certificates are checked unless FIREFLY_SMTP_VERIFY=false: against the
        # system's CAs, or FIREFLY_SMTP_CA_CERT_FILE.
        tls_options =
          if System.get_env("FIREFLY_SMTP_VERIFY") in ~w(false 0) do
            [verify: :verify_none]
          else
            cas =
              if file = System.get_env("FIREFLY_SMTP_CA_CERT_FILE"),
                do: [cacertfile: file],
                else: [cacerts: :public_key.cacerts_get()]

            [
              verify: :verify_peer,
              versions: [:"tlsv1.2", :"tlsv1.3"],
              server_name_indication: String.to_charlist(relay),
              depth: 99,
              customize_hostname_check: [
                match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
              ]
            ] ++ cas
          end

        modes = %{"always" => :always, "if_available" => :if_available, "never" => :never}
        default_port = if ssl?, do: "465", else: "587"

        [
          adapter: Swoosh.Adapters.SMTP,
          relay: relay,
          port: String.to_integer(System.get_env("FIREFLY_SMTP_PORT", default_port)),
          username: System.get_env("FIREFLY_SMTP_USERNAME"),
          password: System.get_env("FIREFLY_SMTP_PASSWORD"),
          # Implicit TLS (FIREFLY_SMTP_SSL, port 465), else STARTTLS.
          ssl: ssl?,
          tls: if(ssl?, do: :never, else: choice.("FIREFLY_SMTP_TLS", "always", modes)),
          auth: choice.("FIREFLY_SMTP_AUTH", "if_available", modes),
          retries: String.to_integer(System.get_env("FIREFLY_SMTP_RETRIES", "2")),
          no_mx_lookups: true,
          tls_options: tls_options,
          sockopts: if(ssl?, do: tls_options, else: [])
        ]

      "ses" ->
        # Static credentials (an IAM user's, or temporary ones with
        # AWS_SESSION_TOKEN): Swoosh's SES adapter doesn't fetch instance or
        # task role credentials itself.
        [
          adapter: Swoosh.Adapters.AmazonSES,
          region:
            System.get_env("FIREFLY_SES_REGION") || System.get_env("AWS_REGION") ||
              required.("AWS_DEFAULT_REGION"),
          access_key: required.("AWS_ACCESS_KEY_ID"),
          secret: required.("AWS_SECRET_ACCESS_KEY"),
          provider_options:
            Map.reject(
              %{
                security_token: System.get_env("AWS_SESSION_TOKEN"),
                configuration_set_name: System.get_env("FIREFLY_SES_CONFIGURATION_SET")
              },
              fn {_key, value} -> is_nil(value) end
            )
        ]

      "sendgrid" ->
        [adapter: Swoosh.Adapters.Sendgrid, api_key: required.("FIREFLY_SENDGRID_API_KEY")]

      "mailgun" ->
        [
          adapter: Swoosh.Adapters.Mailgun,
          api_key: required.("FIREFLY_MAILGUN_API_KEY"),
          domain: required.("FIREFLY_MAILGUN_DOMAIN"),
          # EU domains: https://api.eu.mailgun.net/v3
          base_url: System.get_env("FIREFLY_MAILGUN_BASE_URL")
        ]

      "postmark" ->
        stream = System.get_env("FIREFLY_POSTMARK_MESSAGE_STREAM")

        [
          adapter: Swoosh.Adapters.Postmark,
          api_key: required.("FIREFLY_POSTMARK_API_KEY"),
          provider_options: if(stream, do: %{message_stream: stream}, else: %{})
        ]

      "local" ->
        [adapter: Swoosh.Adapters.Local]

      other ->
        raise "FIREFLY_MAIL_ADAPTER=#{other} isn't one of smtp, ses, sendgrid, mailgun, postmark, local"
    end

  config :firefly, Firefly.Mailer, mail
end

if config_env() == :prod and is_nil(mail_adapter) do
  raise """
  no outbound email is configured: set FIREFLY_MAIL_ADAPTER to smtp, ses,
  sendgrid, mailgun, postmark or local, with that adapter's variables (see
  "Email" in README.md).
  """
end

# Each job queue's concurrency on this node (see Firefly.Jobs):
# FIREFLY_JOBS_<QUEUE>=<n>, e.g. FIREFLY_JOBS_MAILERS=20; 0 runs none of
# that queue's jobs here (another node does).
if config_env() != :test do
  queues =
    for {queue, _default} <- Application.get_env(:firefly, Oban)[:queues],
        limit = System.get_env("FIREFLY_JOBS_#{String.upcase(to_string(queue))}"),
        do: {queue, String.to_integer(limit)}

  if queues != [], do: config(:firefly, Oban, queues: queues)
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
# OTEL_* variables: nothing is exported without an OTLP endpoint. Metrics
# and logs over OTLP are opt-in on top.
otel_endpoint? = fn signal ->
  System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") != nil or
    System.get_env("OTEL_EXPORTER_OTLP_#{signal}_ENDPOINT") != nil
end

if config_env() != :test do
  traces? =
    otel_endpoint?.("TRACES") and System.get_env("OTEL_TRACES_EXPORTER", "otlp") != "none"

  metrics? =
    otel_endpoint?.("METRICS") and System.get_env("OTEL_METRICS_EXPORTER", "otlp") != "none" and
      System.get_env("FIREFLY_OTEL_METRICS") in ~w(true 1)

  logs? = otel_endpoint?.("LOGS") and System.get_env("FIREFLY_OTEL_LOGS") in ~w(true 1)

  config :firefly_web, FireflyWeb.OpenTelemetry, traces: traces?, metrics: metrics?, logs: logs?

  if traces?, do: config(:opentelemetry, traces_exporter: :otlp)

  # The SDK reads its variables itself; OtelMetricExporter reads them too,
  # but not as the spec (and the SDK) does, so they're mapped here: a
  # signal's own variable wins, its endpoint is the full URL, and header
  # values may contain "=". The resource is the traces' (see
  # FireflyWeb.Telemetry).
  if metrics? do
    otlp_env = fn var ->
      System.get_env("OTEL_EXPORTER_OTLP_METRICS_#{var}") ||
        System.get_env("OTEL_EXPORTER_OTLP_#{var}")
    end

    protocol = otlp_env.("PROTOCOL") || "http/protobuf"

    if protocol != "http/protobuf" do
      raise "FIREFLY_OTEL_METRICS sends OTLP over http/protobuf only, not #{protocol}: " <>
              "set OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/protobuf " <>
              "(and OTEL_EXPORTER_OTLP_METRICS_ENDPOINT to the collector's HTTP port)"
    end

    # The exporter appends /v1/metrics itself.
    endpoint =
      if url = System.get_env("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"),
        do: String.replace_suffix(url, "/v1/metrics", ""),
        else: String.trim_trailing(System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT"), "/")

    headers =
      for pair <- String.split(otlp_env.("HEADERS") || "", ",", trim: true),
          [key, value] <- [String.split(pair, "=", parts: 2)],
          into: %{},
          do: {String.trim(key), String.trim(value)}

    config :otel_metric_exporter,
      otlp_endpoint: endpoint,
      otlp_headers: headers,
      otlp_timeout: String.to_integer(otlp_env.("TIMEOUT") || "10000"),
      export_period: String.to_integer(System.get_env("OTEL_METRIC_EXPORT_INTERVAL", "60000"))
  end
end

# How long a shutting-down node fails readiness probes before the endpoint
# stops listening (see FireflyWeb.Draining).
if delay = System.get_env("FIREFLY_DRAIN_DELAY_MS") do
  config :firefly_web, FireflyWeb.Draining, delay: String.to_integer(delay)
end

# Clustering (see Firefly.Cluster and "Running several nodes" in README.md):
# off unless FIREFLY_CLUSTER=postgres, which finds the other nodes through
# the database. FIREFLY_CLUSTER_NAME keeps deployments sharing a database
# server apart (their own Postgres channel).
case System.get_env("FIREFLY_CLUSTER", "") do
  off when off in ["", "none", "false", "0"] ->
    :ok

  "postgres" ->
    channel =
      case System.get_env("FIREFLY_CLUSTER_NAME", "") do
        "" ->
          "firefly_cluster"

        name ->
          # Part of a Postgres identifier: short, and nothing to quote.
          if not Regex.match?(~r/\A[a-z0-9_]{1,40}\z/, name),
            do: raise("FIREFLY_CLUSTER_NAME must be 1-40 of a-z, 0-9 and _")

          "firefly_cluster_" <> name
      end

    # A release started without RELEASE_COOKIE uses the cookie baked into
    # it at build time, which anyone with the image has: a cluster would
    # accept them as a node.
    if config_env() == :prod do
      cookie = System.get_env("RELEASE_COOKIE", "")

      built_in =
        case File.read(Path.join(System.get_env("RELEASE_ROOT", ""), "releases/COOKIE")) do
          {:ok, built_in} -> String.trim(built_in)
          {:error, _} -> nil
        end

      if String.length(cookie) < 32 or cookie == built_in,
        do:
          raise("""
          FIREFLY_CLUSTER=postgres needs RELEASE_COOKIE: a random secret of at
          least 32 characters, the same on every node (e.g. openssl rand -hex 32).
          """)
    end

    config :firefly, Firefly.Cluster,
      strategy: :postgres,
      channel: channel,
      heartbeat_interval:
        String.to_integer(System.get_env("FIREFLY_CLUSTER_HEARTBEAT_MS", "5000"))

  other ->
    raise "FIREFLY_CLUSTER must be postgres or unset, got: #{inspect(other)}"
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

  config :firefly, :email,
    from: {"Firefly", System.get_env("FIREFLY_EMAIL_FROM", "noreply@#{host}")},
    reply_domain: System.get_env("FIREFLY_REPLY_EMAIL_DOMAIN", "reply.#{host}"),
    inbound_token: System.get_env("FIREFLY_INBOUND_EMAIL_TOKEN")
end
