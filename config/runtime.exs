import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

if System.get_env("FIREFLY_SERVER") do
  config :firefly_web, FireflyWeb.Endpoint, server: true
end

# Only admins create new tags; members pick existing ones.
if System.get_env("FIREFLY_TAGS_ADMIN_ONLY") in ~w(true 1) do
  config :firefly, tags_admin_only: true
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
