defmodule FireflyImport.MixProject do
  use Mix.Project

  # Importers from other forums and chat platforms: each reads its source
  # (a database, an export file or an API) and hands the records to the
  # domain's `Firefly.Import`, which writes them. A separate app so the
  # database drivers and parsers only importers need stay out of the
  # domain; it's in the release, for `bin/firefly eval`.
  def project do
    [
      app: :firefly_import,
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
      compilers: [:boundary] ++ Mix.compilers()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Enforces the contexts' public APIs at compile time (see the Firefly module).
      {:boundary, "~> 0.12.0", runtime: false},
      {:firefly, in_umbrella: true},
      {:jason, "~> 1.4"},
      # Discourse's database.
      {:postgrex, "~> 0.22"},
      # As in firefly_web (Kaffy's optional `decimal ~> 2.2`): the umbrella's
      # apps must agree on it, and Postgrex brings it in here too.
      {:decimal, "~> 3.2", override: true},
      # phpBB's and vBulletin's MySQL (or MariaDB) databases.
      {:myxql, "~> 0.9.0"},
      # NodeBB's database: MongoDB or Redis.
      {:mongodb_driver, "~> 1.6"},
      {:redix, "~> 1.5"},
      # HTML to Markdown.
      {:floki, "~> 0.38"},
      # Files to download (uploads given by URL).
      {:req, "~> 0.7.5"},
      # Property-based tests of the HTML to Markdown conversion.
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      test: [
        "ecto.create --quiet -r Firefly.Repo",
        "ecto.migrate --quiet -r Firefly.Repo",
        "test"
      ]
    ]
  end
end
