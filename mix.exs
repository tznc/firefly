defmodule FirestormWeb.Mixfile do
  use Mix.Project

  def project do
    [
      app: :firestorm_web,
      version: "0.10.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [plt_add_apps: [:mix, :ex_unit], plt_local_path: "priv/plts"]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [mod: {FirestormWeb.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_view, "~> 2.0"},
      {:phoenix_html, "~> 4.4"},
      {:phoenix_html_helpers, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:bandit, "~> 1.14"},
      {:jason, "~> 1.4"},
      {:gettext, "~> 1.0"},
      {:ueberauth, "~> 0.11"},
      {:ueberauth_github, "~> 0.8"},
      {:ueberauth_identity, "~> 0.4"},
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
      {:cors_plug, "~> 3.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:dart_sass, "~> 0.8", runtime: Mix.env() == :dev},

      # TEST DEPENDENCIES
      {:wallaby, "~> 0.31", only: :test, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # DEV DEPENDENCIES
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to create, migrate and run the seeds file at once:
  #
  #     $ mix ecto.setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["esbuild.install --if-missing", "sass.install --if-missing"],
      "assets.build": ["esbuild firestorm_web", "sass default"],
      "assets.deploy": [
        "esbuild firestorm_web --minify",
        "sass default --no-source-map --style=compressed",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict",
        "test"
      ]
    ]
  end
end
