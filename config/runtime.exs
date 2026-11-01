import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

if System.get_env("FIREFLY_SERVER") do
  config :firestorm_web, FirestormWeb.Web.Endpoint, server: true
end

# Only admins create new tags; members pick existing ones.
if System.get_env("FIREFLY_TAGS_ADMIN_ONLY") in ~w(true 1) do
  config :firestorm_web, tags_admin_only: true
end

# Reverse proxies (addresses or CIDR ranges, comma-separated) whose
# X-Forwarded-For header gives the client IP; see FirestormWeb.Web.ClientIP.
config :firestorm_web, FirestormWeb.Web.ClientIP,
  trusted_proxies: String.split(System.get_env("FIREFLY_TRUSTED_PROXIES", ""), ",", trim: true)

if config_env() != :test do
  config :ueberauth, Ueberauth.Strategy.Github.OAuth,
    client_id: System.get_env("FIREFLY_GITHUB_CLIENT_ID"),
    client_secret: System.get_env("FIREFLY_GITHUB_CLIENT_SECRET")

  # Configuration for AWS integration
  config :firestorm_web, :aws,
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

  config :firestorm_web, FirestormWeb.Repo,
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

  config :firestorm_web, FirestormWeb.Web.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: ip, port: port],
    secret_key_base: secret_key_base

  config :firestorm_web, FirestormWeb.Mailer,
    adapter: Bamboo.SendGridAdapter,
    api_key: System.get_env("FIREFLY_SENDGRID_API_KEY")

  config :firestorm_web, :email,
    from: {"Firefly", System.get_env("FIREFLY_EMAIL_FROM", "noreply@#{host}")},
    reply_domain: System.get_env("FIREFLY_REPLY_EMAIL_DOMAIN", "reply.#{host}"),
    inbound_token: System.get_env("FIREFLY_INBOUND_EMAIL_TOKEN")
end
