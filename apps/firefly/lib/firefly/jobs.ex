defmodule Firefly.Jobs do
  @moduledoc """
  The Jobs context: background and scheduled work, run by
  [Oban](https://hexdocs.pm/oban) from the `oban_jobs` table in PostgreSQL.

  The database coordinates every node, with no distributed Erlang: jobs
  are taken with `SELECT ... FOR UPDATE SKIP LOCKED`, queues are told of
  new jobs through `LISTEN/NOTIFY` (`Oban.Notifiers.Postgres`), and one node
  at a time leads (`Oban.Peers.Database`), running what must run once per
  cluster (the pruner, scheduled cron jobs).

  Periodic work runs on cron schedules (see `Firefly.Jobs.Periodic`).
  Queues and their concurrency are configured in `config :firefly, Oban`
  (from `FIREFLY_JOBS_<QUEUE>` in production; see `queues/0`). Finished
  jobs (completed, cancelled, discarded) are kept `job_retention_days` (a
  site setting) and then pruned (see `Firefly.Jobs.Pruner`).

  `insert/1` enqueues a job with the caller's trace context, so its spans
  join the enqueuer's trace.
  """

  use Boundary, top_level?: true, check: [out: false], exports: []

  import Ecto.Query

  alias Firefly.Repo

  @states ~w(available scheduled executing retryable completed cancelled discarded)

  @doc "Enqueues `changeset` (a worker's `new/2`), carrying the trace context."
  @spec insert(Ecto.Changeset.t()) :: {:ok, Oban.Job.t()} | {:error, term}
  def insert(%Ecto.Changeset{} = changeset), do: OpentelemetryOban.insert(changeset)

  @doc "The periodic tasks' cron schedule (see `Firefly.Jobs.Periodic`)."
  @spec crontab() :: [{String.t(), module}]
  defdelegate crontab, to: Firefly.Jobs.Periodic

  @doc """
  Runs the periodic task `name` (`:TopicTimers` or `:BookmarkReminders`)
  at `at` too, besides its schedule: a timer or reminder fires on time
  rather than at the next sweep.
  """
  @spec run_at(:TopicTimers | :BookmarkReminders, DateTime.t()) :: {:ok, Oban.Job.t()}
  def run_at(name, %DateTime{} = at) when name in [:TopicTimers, :BookmarkReminders] do
    # Not unique: each timer gets its own run, whatever else is scheduled.
    name
    |> Firefly.Jobs.Periodic.worker()
    |> apply(:new, [%{}, [scheduled_at: at, unique: false]])
    |> insert()
  end

  @doc "The configured queues' names."
  @spec queues() :: [atom]
  def queues, do: Keyword.keys(Application.get_env(:firefly, Oban, [])[:queues] || [])

  @doc "The job states, as Oban names them."
  def states, do: @states

  @doc """
  How many jobs each queue has in each state: `%{{queue, state} => count}`,
  zero included, for every configured queue (and any other with jobs).
  """
  @spec counts() :: %{{String.t(), String.t()} => non_neg_integer}
  def counts do
    found =
      Repo.all(
        from(j in "oban_jobs",
          group_by: [j.queue, j.state],
          select: {{j.queue, j.state}, count()}
        )
      )

    zeros = for queue <- queues(), state <- @states, into: %{}, do: {{to_string(queue), state}, 0}
    Map.merge(zeros, Map.new(found))
  end

  @doc """
  Oban's status on this node, for the readiness probe: `running` (Oban is
  up here) and `leader` (this node runs the cluster-wide work).
  """
  @spec status() :: %{running: boolean, leader: boolean}
  def status do
    case Oban.whereis(Oban) do
      nil -> %{running: false, leader: false}
      _pid -> %{running: true, leader: Oban.Peer.leader?(Oban)}
    end
  end

  @doc "How many days finished jobs are kept (the `job_retention_days` setting)."
  @spec retention_days() :: pos_integer
  def retention_days, do: Firefly.SiteSettings.get("job_retention_days")
end
