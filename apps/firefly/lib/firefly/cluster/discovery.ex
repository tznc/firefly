defmodule Firefly.Cluster.Discovery do
  @moduledoc """
  Runs libcluster's `Cluster.Supervisor` with `Firefly.Cluster.topologies/0`,
  restarting it with a backoff when it gives up.

  The Postgres strategy crashes whenever its database connection fails
  (at boot, or when Postgres restarts), faster than any supervisor's
  restart intensity allows. Supervised directly, that would take the
  domain's supervisor, and the node, down with it; here a database outage
  only pauses discovery. Nodes already connected stay connected.
  """
  use GenServer
  require Logger

  @min_backoff 1_000
  @max_backoff 30_000

  @doc """
  Starts discovery. `topologies` (a function returning them) stands in for
  `Firefly.Cluster.topologies/0` in tests.
  """
  def start_link(opts) do
    topologies = Keyword.get(opts, :topologies, &Firefly.Cluster.topologies/0)
    GenServer.start_link(__MODULE__, topologies, name: __MODULE__)
  end

  @impl true
  def init(topologies) do
    Process.flag(:trap_exit, true)

    {:ok, %{topologies: topologies, supervisor: nil, started_at: nil, backoff: @min_backoff},
     {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, start(state)}

  @impl true
  def handle_info(:start, state), do: {:noreply, start(state)}

  def handle_info({:EXIT, pid, reason}, %{supervisor: pid} = state) do
    # Back to the shortest delay after a long enough run.
    backoff =
      if now() - state.started_at > @max_backoff, do: @min_backoff, else: state.backoff

    Logger.warning(
      "Cluster discovery stopped (#{Exception.format_exit(reason)}); restarting in #{backoff}ms"
    )

    {:noreply, retry(%{state | supervisor: nil}, backoff)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp start(state) do
    # The topologies are read on each start, so no password stays in this state.
    case Cluster.Supervisor.start_link([state.topologies.(), [name: Firefly.Cluster.Supervisor]]) do
      {:ok, pid} ->
        %{state | supervisor: pid, started_at: now()}

      {:error, reason} ->
        Logger.warning("Cluster discovery didn't start (#{inspect(reason)}); retrying")
        retry(state, state.backoff)
    end
  end

  defp retry(state, backoff) do
    Process.send_after(self(), :start, backoff)
    %{state | backoff: min(backoff * 2, @max_backoff)}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
