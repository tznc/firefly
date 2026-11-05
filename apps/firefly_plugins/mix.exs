defmodule FireflyPlugins.MixProject do
  use Mix.Project

  # The sandbox uploaded plugins run in: QuickJS compiled to WebAssembly, on
  # wasmtime (Wasmex). It implements `Firefly.Plugin` and registers itself
  # with the domain when it starts.
  def project do
    [
      app: :firefly_plugins,
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
    [mod: {FireflyPlugins.Application, []}, extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Enforces the contexts' public APIs at compile time (see the Firefly module).
      {:boundary, "~> 0.10.4", runtime: false},
      {:firefly, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:wasmex, "~> 0.15.1"}
    ]
  end

  defp aliases do
    [
      test: [
        "ecto.create --quiet -r Firefly.Repo",
        "firefly.control.migrate --quiet",
        "ecto.migrate --quiet -r Firefly.Repo",
        "test"
      ]
    ]
  end
end
