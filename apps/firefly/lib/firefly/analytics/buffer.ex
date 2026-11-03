defmodule Firefly.Analytics.Buffer do
  @moduledoc """
  Where `Firefly.Analytics` counts in memory between writes: a public ETS
  table that requests write to directly (no message to a process, so
  counting costs a counter update), owned by this process, which flushes
  it to the database every `:flush_interval` milliseconds (the
  `Firefly.Analytics` config; 10 seconds by default, `:manual` in tests)
  and when the app stops.
  """
  use GenServer
  require Logger

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Adds 1 to the counter `key`."
  def increment(key) do
    :ets.update_counter(@table, key, 1, {key, 0})
    :ok
  rescue
    # Not started (e.g. a script without the app): nothing is counted.
    ArgumentError -> :ok
  end

  @doc "Records `key` (once)."
  def put(key) do
    :ets.insert(@table, {key, 1})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Takes everything counted so far, leaving the table empty. A counter
  bumped while this runs is only lowered by what was read, so no count is
  lost.
  """
  def take do
    entries = :ets.tab2list(@table)

    for {key, n} <- entries do
      case key do
        {:view, _, _, _} -> :ets.delete(@table, key)
        _counter -> :ets.update_counter(@table, key, -n)
      end
    end

    :ets.select_delete(@table, [{{:_, 0}, [], [true]}])
    entries
  rescue
    ArgumentError -> []
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

    interval =
      opts[:flush_interval] ||
        Application.get_env(:firefly, Firefly.Analytics, [])[:flush_interval] || 10_000

    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state), do: flush()

  # A failed write is logged and its counts dropped: retrying would only
  # fail the same way.
  defp flush do
    Firefly.Analytics.flush()
  rescue
    error -> Logger.error("Writing analytics failed: " <> Exception.message(error))
  end

  defp schedule(:manual), do: :ok
  defp schedule(interval), do: Process.send_after(self(), :flush, interval)
end
