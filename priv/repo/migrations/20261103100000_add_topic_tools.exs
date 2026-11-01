defmodule FirestormWeb.Repo.Migrations.AddTopicTools do
  use Ecto.Migration

  def change do
    alter table(:forums_threads) do
      # Set on a thread whose posts were merged into another: a closed stub
      # that redirects there (see FirestormWeb.TopicTools).
      add :merged_into_id, references(:forums_threads, on_delete: :nilify_all)
      # Slow mode: the least time between one member's replies; nil: off.
      add :slow_mode_seconds, :integer
    end

    create index(:forums_threads, [:merged_into_id], where: "merged_into_id IS NOT NULL")

    # One pending timer per thread (see FirestormWeb.TopicTimers): close,
    # open or delete it at `run_at`. The row goes once it has run.
    create table(:forums_thread_timers) do
      add :thread_id, references(:forums_threads, on_delete: :delete_all), null: false
      add :action, :string, null: false
      add :run_at, :utc_datetime, null: false
      add :created_by_id, references(:forums_users, on_delete: :delete_all), null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_thread_timers, [:thread_id])
    create index(:forums_thread_timers, [:run_at])
  end
end
