defmodule Firefly.PeriodicJobsTest do
  # Not async: read-only mode is node-wide.
  use Firefly.DataCase, async: false

  import Firefly.Fixtures

  alias Firefly.{Backups, Jobs, SiteSettings}
  alias Firefly.Jobs.Periodic
  alias Firefly.Moderation.{ThreadTimer, TopicTimers}

  test "every periodic task is a worker on a valid cron schedule" do
    crontab = Jobs.crontab()
    assert length(crontab) == 20

    for {expression, worker} <- crontab do
      assert {:ok, _} = Oban.Cron.Expression.parse(expression), expression
      changeset = worker.new(%{})
      assert Ecto.Changeset.get_field(changeset, :max_attempts) == 1
      assert String.to_existing_atom(Ecto.Changeset.get_field(changeset, :queue)) in Jobs.queues()
    end
  end

  test "a task isn't enqueued again while its last run waits" do
    assert {:ok, %{conflict?: false}} = Jobs.insert(Periodic.Badges.new(%{}))
    assert {:ok, %{conflict?: true}} = Jobs.insert(Periodic.Badges.new(%{}))
  end

  test "nothing runs while the site is read-only" do
    admin = admin_fixture()
    thread = thread_fixture(category_fixture(), admin)
    at = DateTime.add(DateTime.utc_now(), 60)
    {:ok, _} = TopicTimers.set_timer(thread, %{action: "close", run_at: at}, admin)
    Repo.update_all(ThreadTimer, set: [run_at: DateTime.add(DateTime.utc_now(), -60)])

    :ok = Backups.set_read_only("Restoring")
    on_exit(fn -> Backups.set_read_only(nil) end)
    assert :ok = perform_job(Periodic.TopicTimers, %{})
    assert [_still_due] = Repo.all(ThreadTimer)

    :ok = Backups.set_read_only(nil)
    assert :ok = perform_job(Periodic.TopicTimers, %{})
    assert Repo.all(ThreadTimer) == []
  end

  describe "scheduled backups" do
    setup do
      dir = Path.join(System.tmp_dir!(), "firefly-periodic-#{System.unique_integer([:positive])}")
      config = Application.get_env(:firefly, Firefly.Backups, [])

      Application.put_env(
        :firefly,
        Firefly.Backups,
        Keyword.merge(config, dir: dir, storage: :local)
      )

      File.mkdir_p!(dir)

      on_exit(fn ->
        Application.put_env(:firefly, Firefly.Backups, config)
        File.rm_rf!(dir)
        SiteSettings.clear_cache()
      end)

      {:ok, _} = SiteSettings.update(%{"backup_frequency_days" => "1"}, admin_fixture())
      %{dir: dir}
    end

    test "wait until the newest backup is old enough", %{dir: dir} do
      File.write!(Path.join(dir, "firefly-2026-01-01-000000.tar.gz"), "x")
      Backups.subscribe()

      assert :ok = Backups.run_due()
      refute_receive {:backup_started, _}, 200
    end
  end
end
