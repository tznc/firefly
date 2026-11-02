defmodule Firefly.Plugins.Registry do
  @moduledoc """
  Plugins on this node: owns the table plugin statistics and the circuit
  breaker count in (see `Firefly.Plugins.Health`), loads the plugins
  from the database at boot (so the first request doesn't pay for it, and a
  broken runtime shows in the log at once), and reloads them when another
  node changes them.
  """
  use GenServer

  require Logger

  alias Firefly.Plugin.Sandbox
  alias Firefly.Plugins
  alias Firefly.Plugins.Health

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Registers the sandbox uploaded plugins run in (see `Firefly.Plugin.Sandbox`)
  and reloads the plugins with it, in the background.
  """
  def register_sandbox(module) do
    Sandbox.register(module)
    Plugins.clear_cache()
    GenServer.cast(__MODULE__, :load)
  end

  @impl true
  def init(_opts) do
    Health.create_table()
    Phoenix.PubSub.subscribe(Firefly.PubSub, Plugins.topic())

    {:ok, %{}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state), do: load(state)

  @impl true
  def handle_cast(:load, state), do: load(state)

  defp load(state) do
    # Prepare the sandbox now rather than in the first plugin call.
    if sandbox = Sandbox.implementation(), do: sandbox.warm_up()

    # Tests load plugins from their own transaction instead.
    if Application.get_env(:firefly, :plugins_cache, true) do
      plugins = Plugins.active()

      if plugins != [],
        do: Logger.info("Plugins loaded: #{Enum.map_join(plugins, ", ", & &1.id)}")
    end

    {:noreply, state}
  rescue
    # A database that isn't up yet mustn't stop the app: plugins then load
    # on first use.
    error ->
      Logger.error("Loading plugins failed: " <> Exception.message(error))
      {:noreply, state}
  end

  @impl true
  def handle_info(:plugins_changed, state) do
    Plugins.clear_cache()
    {:noreply, state}
  end
end
