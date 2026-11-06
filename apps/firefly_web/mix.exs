defmodule FireflyWeb.MixProject do
  use Mix.Project

  # The web interface: endpoint, router, LiveViews, controllers, channels,
  # the JSON API, the staff admin and the assets.
  def project do
    [
      app: :firefly_web,
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
      listeners: [Phoenix.CodeReloader],
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers()
    ]
  end

  def application do
    [mod: {FireflyWeb.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Enforces the contexts' public APIs at compile time (see the Firefly module).
      {:boundary, "~> 0.12.0", runtime: false},
      {:firefly, in_umbrella: true},
      {:firefly_plugins, in_umbrella: true},
      {:phoenix, "~> 1.8.16"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.4"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      # Validates API responses against the OpenAPI document's schemas.
      {:ex_json_schema, "~> 0.11.1", only: :test},
      {:phoenix_test, "~> 0.14", only: :test, runtime: false},
      {:phoenix_test_playwright, "~> 0.19", only: :test, runtime: false},
      {:bandit, "~> 1.14"},
      # The development mailbox at /dev/mailbox (Plug.Swoosh.MailboxPreview).
      {:swoosh, "~> 1.29"},
      # The jobs dashboard at /staff/jobs (see FireflyWeb.JobsResolver).
      {:oban_web, "~> 2.13"},
      {:opentelemetry_oban, "~> 1.2"},
      # Metrics (see FireflyWeb.Telemetry): the definitions, VM and queue
      # measurements, and Peep, which aggregates them for Prometheus in
      # fixed buckets (memory stays flat however rarely it's scraped).
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},
      {:peep, "~> 5.0"},
      # OpenTelemetry (see FireflyWeb.OpenTelemetry): the SDK and OTLP
      # exporter, and spans for Bandit, Phoenix (with LiveView) and Ecto.
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.11"},
      {:opentelemetry_bandit, "~> 0.3.0"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      # Metrics over OTLP, from the same Telemetry.Metrics definitions as
      # Prometheus (with FIREFLY_OTEL_METRICS).
      {:otel_metric_exporter, "~> 0.4.4"},
      # Logs over OTLP are still experimental in the Erlang SDK: pinned, and
      # only used with FIREFLY_OTEL_LOGS.
      {:opentelemetry_experimental, "== 0.6.0"},
      {:jason, "~> 1.4"},
      {:gettext, "~> 1.0"},
      # The optional raw-records admin at /staff/db (see FireflyWeb.Admin).
      {:kaffy, "~> 0.11.0"},
      # Kaffy 0.11 declares an optional `decimal ~> 2.2`; it only uses
      # Decimal.parse/1, integer?/1 and to_integer/1, all unchanged in 3.x.
      {:decimal, "~> 3.2", override: true},
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
       depth: 1}
    ]
  end

  defp aliases do
    [
      test: [
        "ecto.create --quiet -r Firefly.Repo",
        "firefly.control.migrate --quiet",
        "ecto.migrate --quiet -r Firefly.Repo",
        "test"
      ],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind firefly_web", "tailwind admin", "esbuild firefly_web"],
      "assets.deploy": [
        "tailwind firefly_web --minify",
        "tailwind admin --minify",
        "esbuild firefly_web --minify",
        "phx.digest"
      ]
    ]
  end
end
