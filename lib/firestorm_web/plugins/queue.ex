defmodule FirestormWeb.Plugins.Queue do
  @moduledoc """
  Runs plugins' background work from the database: delivers queued events
  (see `FirestormWeb.Plugins.Events`) every `:interval` milliseconds (1
  second by default) and at once when one is queued on this node, and runs
  due scheduled jobs (see `FirestormWeb.Plugins.Jobs`) every
  `:jobs_interval` (15 seconds). Both take their rows one locked transaction
  at a time, so several nodes share the work and each item runs once.

  Off in tests (`config :firestorm_web, FirestormWeb.Plugins.Queue,
  enabled: false`), which run the work inside their own transaction.
  """
  use GenServer

  require Logger

  alias FirestormWeb.Plugins.{Events, Jobs}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Asks the queue to deliver what's due now (no-op if it isn't running)."
  def kick do
    if pid = Process.whereis(__MODULE__), do: send(pid, :kick)
    :ok
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:firestorm_web, __MODULE__, [])

    state = %{
      interval: config[:interval] || 1_000,
      jobs_interval: config[:jobs_interval] || 15_000
    }

    send(self(), :deliver)
    send(self(), :jobs)
    {:ok, state}
  end

  @impl true
  def handle_info(:deliver, state) do
    deliver()
    Process.send_after(self(), :deliver, state.interval)
    {:noreply, state}
  end

  def handle_info(:kick, state) do
    deliver()
    {:noreply, state}
  end

  def handle_info(:jobs, state) do
    safely(&Jobs.run_due/0)
    Process.send_after(self(), :jobs, state.jobs_interval)
    {:noreply, state}
  end

  defp deliver do
    # Kicks that arrived meanwhile are covered by this run.
    flush(:kick)
    safely(&Events.deliver_due/0)
  end

  defp flush(message) do
    receive do
      ^message -> flush(message)
    after
      0 -> :ok
    end
  end

  # A failure is logged, not fatal: the work stays queued for the next run.
  defp safely(work) do
    work.()
  rescue
    error -> Logger.error("Plugin queue: " <> Exception.message(error))
  end
end
