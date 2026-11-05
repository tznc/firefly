defmodule Firefly.Jobs.Pruner do
  @moduledoc """
  Deletes finished jobs (completed, cancelled, discarded) older than the
  `job_retention_days` site setting, read on every run, so an admin's change
  applies without a restart (Oban's own pruner reads its `max_age` once, at
  start). Runs every minute on the leading node only, at most `limit` jobs
  (10,000) a run; reports as an Oban plugin (`[:oban, :plugin, ...]` with
  `pruned_count`).
  """
  @behaviour Oban.Plugin

  use GenServer

  alias Oban.{Engine, Job, Peer, Repo}

  @impl Oban.Plugin
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @impl Oban.Plugin
  def validate(opts) do
    Oban.Validation.validate_schema(opts,
      conf: :any,
      name: :any,
      interval: :pos_integer,
      limit: :pos_integer
    )
  end

  @impl GenServer
  def init(state) do
    state = Map.merge(%{interval: :timer.minutes(1), limit: 10_000}, state)
    :telemetry.execute([:oban, :plugin, :init], %{}, %{conf: state.conf, plugin: __MODULE__})
    {:ok, schedule(state)}
  end

  @impl GenServer
  def handle_info(:prune, state) do
    meta = %{conf: state.conf, plugin: __MODULE__}

    :telemetry.span([:oban, :plugin], meta, fn ->
      pruned = if Peer.leader?(state.conf), do: prune(state.conf, state.limit), else: 0
      {:ok, Map.put(meta, :pruned_count, pruned)}
    end)

    {:noreply, schedule(state)}
  end

  @doc """
  Deletes up to `limit` finished jobs older than the `job_retention_days`
  setting now: how many went. The plugin calls it on the leading node only.
  """
  @spec prune(Oban.Config.t(), pos_integer) :: non_neg_integer
  def prune(conf, limit) do
    max_age = Firefly.Jobs.retention_days() * 86_400

    {:ok, pruned} =
      Repo.transaction(conf, fn ->
        {:ok, jobs} = Engine.prune_jobs(conf, Job, limit: limit, max_age: max_age)
        jobs
      end)

    length(pruned)
  end

  defp schedule(state),
    do: Map.put(state, :timer, Process.send_after(self(), :prune, state.interval))
end
