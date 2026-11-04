defmodule Firefly.Umbrella.MixProject do
  use Mix.Project

  # The umbrella: `apps/firefly` (the domain), `apps/firefly_plugins` (the
  # sandboxed plugin runtime), `apps/firefly_web` (the web interface) and
  # `apps/firefly_import` (importers from other forums and platforms).
  # Dependencies live in the app that uses them; only tools that run from the
  # root are declared here.
  def project do
    [
      apps_path: "apps",
      version: "0.10.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # One release with all four apps, started in dependency order. The
  # importers start nothing: they run from `bin/firefly eval`.
  defp releases do
    [
      firefly: [
        applications: [
          firefly: :permanent,
          firefly_plugins: :permanent,
          firefly_web: :permanent,
          firefly_import: :load
        ]
      ]
    ]
  end

  # The app-specific aliases (`test`, `ecto.*`, `assets.*`) are defined in the
  # apps and run in each of them from here.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
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
