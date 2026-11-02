defmodule FirestormWeb.Plugin.Sandboxed do
  @moduledoc """
  The `FirestormWeb.Plugin` implementation for uploaded plugins: their
  JavaScript runs in QuickJS on WebAssembly (see
  `FirestormWeb.Plugin.Sandboxed.Runtime` for the limits), a fresh instance
  per hook call.

  A hook `name` calls the bundle's exported handler of the same name with
  one argument, the hook's input, and its result (or a promise of it) is
  the hook's result. The sandbox has the standard JavaScript built-ins and
  one global of Firefly's:

      firefly.plugin          // {id, version, settings}
      firefly.call(name, args) // a host function; throws on errors
      firefly.log(...values)   // also console.log/info/warn/error

  See `FirestormWeb.Plugin.Host` for the host functions.
  """

  @behaviour FirestormWeb.Plugin

  alias FirestormWeb.Plugin
  alias FirestormWeb.Plugin.{Host, Manifest}
  alias FirestormWeb.Plugin.Sandboxed.Runtime
  alias FirestormWeb.Plugins.InstalledPlugin

  @impl true
  def load(%InstalledPlugin{manifest: attrs, code: code}) when is_binary(code) do
    with {:ok, manifest} <- Manifest.parse(attrs, "upload"), do: {:ok, manifest, %{code: code}}
  end

  def load(_spec), do: {:error, "The plugin's bundle is missing."}

  @impl true
  def enabled(%Plugin{} = plugin), do: lifecycle(plugin, "enabled")

  @impl true
  def disabled(%Plugin{} = plugin), do: lifecycle(plugin, "disabled")

  defp lifecycle(plugin, hook) do
    with {:ok, _} <- run(plugin, hook, %{}), do: :ok
  end

  @impl true
  def call_export(%Plugin{} = plugin, function, args), do: run(plugin, function, args)

  @doc """
  Runs the plugin's handler `hook` with `input`. The time limit is the
  runner's (see `FirestormWeb.Plugin.Runner`), less a margin so the sandbox
  reports a timeout before the runner gives up on it.
  """
  @spec run(Plugin.t(), String.t(), term) :: {:ok, term} | {:error, Plugin.failure()}
  def run(%Plugin{} = plugin, hook, input) do
    config = Application.get_env(:firestorm_web, __MODULE__, [])

    opts =
      config
      |> Keyword.take([:memory, :fuel, :max_output])
      |> Keyword.put(:host, &Host.call(plugin, &1, &2))
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
