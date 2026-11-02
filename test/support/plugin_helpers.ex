defmodule FirestormWeb.PluginHelpers do
  @moduledoc "Builds plugin bundles and installs plugins for tests."

  alias FirestormWeb.Plugin.Bundle
  alias FirestormWeb.Plugins

  @doc """
  A plugin bundle (.zip binary): `manifest` merged into a minimal valid one
  (string keys), and `files` (path => contents), `index.js` by default.
  """
  def bundle_zip(manifest \\ %{}, files \\ %{"index.js" => "exports.enabled = () => null;"}) do
    manifest =
      Map.merge(
        %{
          "id" => "test-plugin",
          "name" => "Test plugin",
          "version" => "1.0.0",
          "firefly" => "~> 1.0"
        },
        manifest
      )

    zip(Map.put(files, "plugin.json", Jason.encode!(manifest)))
  end

  @doc "A .zip of `files` (path => contents)."
  def zip(files) do
    entries = for {path, data} <- files, do: {String.to_charlist(path), data}
    {:ok, {_name, zip}} = :zip.create(~c"plugin.zip", entries, [:memory])
    zip
  end

  @doc "Installs a bundle (see `bundle_zip/2`) as `admin`, optionally enabling it."
  def install_plugin!(admin, manifest \\ %{}, files \\ nil, opts \\ []) do
    zip = if files, do: bundle_zip(manifest, files), else: bundle_zip(manifest)
    {:ok, bundle} = Bundle.read(zip)
    {:ok, _row} = Plugins.install(bundle, admin)
    if opts[:enable], do: {:ok, _} = Plugins.enable(bundle.manifest.id, admin)
    bundle.manifest.id
  end

  @doc "Runs `fun` with `modules` as the core plugins."
  def with_core_plugins(modules, fun) do
    previous = Application.get_env(:firestorm_web, Plugins, [])
    Application.put_env(:firestorm_web, Plugins, Keyword.put(previous, :core, modules))

    try do
      fun.()
    after
      Application.put_env(:firestorm_web, Plugins, previous)
    end
  end
end

defmodule FirestormWeb.Test.GreeterPlugin do
  @moduledoc """
  A tiny core plugin for tests: exports `greet`, using an uploaded plugin's
  `shout` when the "loud" plugin is installed (an optional dependency).
  """
  use FirestormWeb.Plugin,
    id: "greeter",
    name: "Greeter",
    version: "1.0.0",
    firefly: "~> 1.0",
    description: "Says hello.",
    author: "Firefly",
    exports: ["greet"],
    optional_dependencies: %{"loud" => "~> 1.0"},
    settings: [%{key: "greeting", type: "string", default: "Hello"}]

  alias FirestormWeb.Plugin.Host

  @impl true
  def call_export(plugin, "greet", %{"name" => name}) do
    greeting = "#{plugin.settings["greeting"]}, #{name}"

    case Host.call(plugin, "plugins.call", %{
           "plugin" => "loud",
           "function" => "shout",
           "args" => greeting
         }) do
      {:ok, loud} -> {:ok, loud}
      {:error, _not_installed} -> {:ok, greeting}
    end
  end

  def call_export(_plugin, "greet", _args), do: {:error, "name is required"}
end

defmodule FirestormWeb.Test.CrashingPlugin do
  @moduledoc "A core plugin for tests whose export raises, needing the uploaded \"base\"."
  use FirestormWeb.Plugin,
    id: "crashing",
    name: "Crashing",
    version: "0.1.0",
    firefly: "~> 1.0",
    exports: ["boom"],
    dependencies: %{"base" => "~> 1.0"}

  @impl true
  def call_export(_plugin, "boom", _args), do: raise("boom")
end
