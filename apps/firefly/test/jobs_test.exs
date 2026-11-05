defmodule Firefly.JobsTest do
  # Not async: the job_retention_days setting is node-wide (cached).
  use Firefly.DataCase, async: false

  use Oban.Testing, repo: Firefly.Repo

  import Firefly.Fixtures

  alias Firefly.{Jobs, SiteSettings}
  alias Firefly.Jobs.Pruner

  defmodule Echo do
    @moduledoc false
    use Oban.Worker, queue: :default
    @impl Oban.Worker
    def perform(%Oban.Job{}) do
      send(Firefly.JobsTest, :ran)
      :ok
    end
  end

  setup do
    on_exit(&SiteSettings.clear_cache/0)
  end

  # A finished job, `days` old.
  defp finished(state, days) do
    at = DateTime.add(DateTime.utc_now(), -days, :day)

    %{id: id} =
      Repo.insert!(%Oban.Job{
        worker: inspect(Echo),
        queue: "default",
        args: %{},
        state: state,
        scheduled_at: at,
        attempted_at: at,
        completed_at: if(state == "completed", do: at),
        cancelled_at: if(state == "cancelled", do: at),
        discarded_at: if(state == "discarded", do: at)
      })

    id
  end

  defp remaining, do: Repo.all(from(j in Oban.Job, select: j.id)) |> MapSet.new()

  defp prune, do: Pruner.prune(Oban.config(Oban), 100)

  test "enqueued jobs wait in their queue; tests run them with Oban.Testing" do
    Process.register(self(), Firefly.JobsTest)
    assert {:ok, %Oban.Job{queue: "default"}} = Jobs.insert(Echo.new(%{}))

    assert_enqueued(worker: Echo, queue: :default)
    assert %{success: 1} = Oban.drain_queue(queue: :default)
    assert_received :ran
  end

  test "finished jobs are pruned after the job_retention_days setting, read on every run" do
    assert Jobs.retention_days() == 14

    for state <- ~w(completed cancelled discarded), do: finished(state, 15)
    recent = for state <- ~w(completed cancelled discarded), do: finished(state, 3)
    # Unfinished jobs are never pruned, however old.
    waiting = finished("available", 30)

    assert prune() == 3
    assert remaining() == MapSet.new([waiting | recent])

    # An admin's change applies at the next run, without a restart.
    {:ok, _} = SiteSettings.update(%{"job_retention_days" => "2"}, admin_fixture())
    assert Jobs.retention_days() == 2
    assert prune() == 3
    assert remaining() == MapSet.new([waiting])
  end

  test "the setting is a typed site setting with bounds" do
    definition = Enum.find(SiteSettings.definitions(), &(&1.key == "job_retention_days"))

    assert %{type: :integer, default: 14, min: 1, section: "Jobs", category: "Advanced"} =
             definition
  end

  test "counts jobs by queue and state, every configured queue included" do
    finished("completed", 1)
    finished("available", 0)

    counts = Jobs.counts()

    assert counts[{"default", "completed"}] == 1
    assert counts[{"default", "available"}] == 1
    assert counts[{"mailers", "available"}] == 0
    assert map_size(counts) == length(Jobs.queues()) * length(Jobs.states())
  end

  test "reports Oban's status, never failing readiness" do
    assert %{running: true, leader: leader} = Jobs.status()
    assert is_boolean(leader)
    assert %{jobs: %{ok: true, running: true}} = Firefly.Health.readiness()
  end
end
