defmodule FireflyPlugins.Sandboxed do
  @moduledoc """
  The `Firefly.Plugin` implementation for uploaded plugins: their
  JavaScript runs in QuickJS on WebAssembly (see
  `FireflyPlugins.Runtime` for the limits), a fresh instance
  per hook call.

  A hook `name` calls the bundle's exported handler of the same name with
  one argument, the hook's input, and its result (or a promise of it) is
  the hook's result. The sandbox has the standard JavaScript built-ins and
  one global of Firefly's:

      firefly.plugin          // {id, version, settings}
      firefly.call(name, args) // a host function; throws on errors
      firefly.log(...values)   // also console.log/info/warn/error

  See `Firefly.Plugin.Host` for the host functions.
  """

  @behaviour Firefly.Plugin
  @behaviour Firefly.Plugin.Sandbox

  alias Firefly.Plugin
  alias Firefly.Plugin.{Host, Manifest, Runner}
  alias FireflyPlugins.{Bundle, Runtime}
  alias Firefly.Plugins.InstalledPlugin

  @impl true
  def load(%InstalledPlugin{manifest: attrs, code: code, checksum: checksum, bundle: zip})
      when is_binary(code) do
    with {:ok, manifest} <- Manifest.parse(attrs, "upload"),
         {:ok, assets} <- assets(manifest, zip),
         do: {:ok, manifest, %{code: code, checksum: checksum, assets: assets}}
  end

  def load(_spec), do: {:error, "The plugin's bundle is missing."}

  # Assets are kept in memory with the loaded plugin: a few files, served
  # often.
  defp assets(%Manifest{assets: []}, _zip), do: {:ok, %{}}

  defp assets(manifest, zip) do
    case Bundle.read(zip) do
      {:ok, bundle} -> {:ok, Map.take(bundle.files, manifest.assets)}
      {:error, message} -> {:error, message}
    end
  end

  @impl Firefly.Plugin.Sandbox
  def bundle_code(bundle), do: Bundle.code(bundle)

  @impl Firefly.Plugin.Sandbox
  def warm_up, do: Runtime.compiled()

  @impl true
  def enabled(%Plugin{} = plugin), do: lifecycle(plugin, "enabled")

  @impl true
  def disabled(%Plugin{} = plugin), do: lifecycle(plugin, "disabled")

  defp lifecycle(plugin, hook) do
    with {:ok, _} <- run(plugin, hook, %{}), do: :ok
  end

  @impl true
  def call_export(%Plugin{} = plugin, function, args), do: run(plugin, function, args)

  @impl true
  def render_post(%Plugin{} = plugin, input), do: run(plugin, "render_post", input)

  @impl true
  def render_shortcodes(%Plugin{} = plugin, input), do: run(plugin, "render_shortcodes", input)

  @impl true
  def handle_event(%Plugin{} = plugin, input), do: run(plugin, "handle_event", input)

  @impl true
  def run_job(%Plugin{} = plugin, input), do: run(plugin, "run_job", input)

  @impl true
  def moderate_post(%Plugin{} = plugin, input), do: run(plugin, "moderate_post", input)

  @impl true
  def flag_created(%Plugin{} = plugin, input), do: run(plugin, "flag_created", input)

  @impl true
  def handle_widget(%Plugin{} = plugin, input), do: run(plugin, "handle_widget", input)

  @impl true
  def render_page(%Plugin{} = plugin, input), do: run(plugin, "render_page", input)

  @impl true
  def render_admin(%Plugin{} = plugin, input), do: run(plugin, "render_admin", input)

  @impl true
  def handle_request(%Plugin{} = plugin, input), do: run(plugin, "handle_request", input)

  @impl true
  def asset(%Plugin{manifest: manifest, state: %{assets: assets}}, path) do
    if path in manifest.assets, do: Map.fetch(assets, path), else: :error
  end

  @doc """
  Runs the plugin's handler `hook` with `input`. The time limit is the
  runner's (see `Firefly.Plugin.Runner`), less a margin so the sandbox
  reports a timeout before the runner gives up on it.
  """
  @spec run(Plugin.t(), String.t(), term) :: {:ok, term} | {:error, Plugin.failure()}
  def run(%Plugin{} = plugin, hook, input) do
    config = Application.get_env(:firefly_plugins, __MODULE__, [])
    # Host calls are answered in the instance's process: they run in this
    # call's context (see `Runner.context/0`).
    context = Runner.context()

    host = fn name, args ->
      Runner.put_context(context)
      Host.call(plugin, name, args)
    end

    opts =
      config
      |> Keyword.take([:memory, :fuel, :max_output])
      |> Keyword.put(:host, host)
      |> Keyword.put(:timeout, max(Process.get(:firefly_plugin_timeout, 2_000) - 50, 10))

    Runtime.run(prelude(plugin) <> plugin.state.code, hook, input, opts)
  end

  # Sets up `firefly` and `console`, keeping the raw bridge out of reach.
  defp prelude(plugin) do
    info =
      Jason.encode!(%{id: plugin.id, version: plugin.manifest.version, settings: plugin.settings})

    """
    (function () {
      var bridge = firefly.__call;
      delete firefly.__call;
      firefly.plugin = Object.freeze(#{info});
      firefly.call = function (name, args) {
        var response = JSON.parse(bridge(String(name), JSON.stringify(args === undefined ? null : args)));
        if (Object.prototype.hasOwnProperty.call(response, "error")) throw new Error(response.error);
        return response.ok;
      };
      function logger(level) {
        return function () {
          var message = Array.prototype.map.call(arguments, function (value) {
            return typeof value === "string" ? value : JSON.stringify(value);
          }).join(" ");
          firefly.call("log", { level: level, message: message });
        };
      }
      firefly.log = logger("info");
      globalThis.console = { log: logger("info"), info: logger("info"), warn: logger("warn"), error: logger("error") };
      Object.freeze(firefly);
    })();
    """
  end
end
