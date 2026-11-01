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
      package: [licenses: ["Apache-2.0"]],
      listeners: [Phoenix.CodeReloader],
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
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
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.4"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_test, "~> 0.14", only: :test, runtime: false},
      {:phoenix_test_playwright, "~> 0.19", only: :test, runtime: false},
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
      {:kaffy, "~> 0.11"},
      # Kaffy 0.11 declares an optional `decimal ~> 2.2`; it only uses
      # Decimal.parse/1, integer?/1 and to_integer/1, all unchanged in 3.x.
      {:decimal, "~> 3.2", override: true},
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
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.7.50",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},

      # TEST DEPENDENCIES
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
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind firestorm_web", "esbuild firestorm_web"],
      "assets.deploy": [
        "tailwind firestorm_web --minify",
        "esbuild firestorm_web --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo",
        "test"
      ]
    ]
  end
end
