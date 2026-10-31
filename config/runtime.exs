import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere.

if System.get_env("PHX_SERVER") do
  config :firestorm_web, FirestormWeb.Web.Endpoint, server: true
end

if config_env() != :test do
  config :ueberauth, Ueberauth.Strategy.Github.OAuth,
    client_id: System.get_env("GITHUB_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_CLIENT_SECRET")

  # Configuration for AWS integration
  config :firestorm_web, :aws,
    access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
    bucket: System.get_env("AWS_S3_BUCKET"),
    region: System.get_env("AWS_S3_REGION")
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :firestorm_web, FirestormWeb.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    ssl: System.get_env("DATABASE_SSL", "true") in ~w(true 1),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST", "forum.firestormforum.org")
  port = String.to_integer(System.get_env("PORT", "4000"))

  config :firestorm_web, FirestormWeb.Web.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  config :firestorm_web, FirestormWeb.Mailer,
    adapter: Bamboo.SendGridAdapter,
    api_key: System.get_env("SENDGRID_API_KEY")
end
