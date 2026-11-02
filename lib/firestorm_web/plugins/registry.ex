defmodule FirestormWeb.Plugins.Registry do
  @moduledoc """
  Plugins on this node: owns the table plugin statistics and the circuit
  breaker count in (see `FirestormWeb.Plugins.Health`), loads the plugins
  from the database at boot (so the first request doesn't pay for it, and a
  broken runtime shows in the log at once), and reloads them when another
  node changes them.
  """
  use GenServer

  require Logger

  alias FirestormWeb.Plugins
  alias FirestormWeb.Plugin.Sandboxed.Runtime
  alias FirestormWeb.Plugins.Health

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Health.create_table()
    Phoenix.PubSub.subscribe(FirestormWeb.PubSub, Plugins.topic())

    {:ok, %{}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    # Compile the sandbox runtime now rather than in the first plugin call.
    Runtime.compiled()

    # Tests load plugins from their own transaction instead.
    if Application.get_env(:firestorm_web, :plugins_cache, true) do
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
