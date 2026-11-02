defmodule Firefly.MixProject do
  use Mix.Project

  # The domain: data, contexts, jobs, email, authentication and the plugin
  # layer. It knows nothing of the web interface or the plugin sandbox.
  def project do
    [
      app: :firefly,
      version: "0.10.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: [licenses: ["Apache-2.0"], links: %{"tznc.dev" => "https://tznc.dev"}]
    ]
  end

  def application do
    [mod: {Firefly.Application, []}, extra_applications: [:logger, :runtime_tools, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_crypto, "~> 2.1"},
      # Safe HTML for rendered posts, search excerpts and emails.
      {:phoenix_html, "~> 4.4"},
      {:jason, "~> 1.4"},
      # ueberauth_google 0.12 pins `ueberauth ~> 0.10.0`; 0.11 only signs the
      # state cookie, inside Ueberauth's own helpers, which strategies just call.
      {:ueberauth, "~> 0.11", override: true},
      {:ueberauth_github, "~> 0.8"},
      {:ueberauth_google, "~> 0.12"},
      {:ueberauth_discord, "~> 0.7"},
      {:ueberauth_facebook, "~> 0.10"},
      {:ueberauth_apple, "~> 0.7"},
      {:ueberauth_identity, "~> 0.4"},
      # Two-factor authentication: TOTP codes, their QR codes, and WebAuthn
      # security keys and passkeys.
      {:nimble_totp, "~> 1.0"},
      {:eqrcode, "~> 0.2.1"},
      {:wax_, "~> 0.7.0"},
      {:mdex, "~> 0.14"},
      {:scrivener_ecto, "~> 3.1"},
      {:bamboo, "~> 2.5"},
      {:ecto_autoslug_field, "~> 3.1"},
      {:bcrypt_elixir, "~> 3.3"},
      {:exgravatar, "~> 2.0"},
      {:bodyguard, "~> 2.4"},
      {:html_sanitize_ex, "~> 1.5"},
      {:oembed, "~> 0.5"},
      {:lru_cache, "~> 0.1.3"},
      {:hammer, "~> 7.5"},
      # Plugins' outgoing HTTP requests (already used by oembed through httpoison).
      {:hackney, "~> 4.9"},
      # Uploaded images: auto-orient, strip metadata, downscale, thumbnails (libvips).
      {:image, "~> 0.72"}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
