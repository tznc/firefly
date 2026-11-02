defmodule FirestormWeb.Repo.Migrations.CreatePluginData do
  use Ecto.Migration

  # What plugins keep and do (see FirestormWeb.Plugins): their bot users,
  # queued event deliveries, scheduled job times, key-value storage and
  # custom fields. Keyed by plugin id; uninstalling a plugin deletes its rows.
  def change do
    alter table(:forums_users) do
      add :plugin_bot, :string
    end

    create unique_index(:forums_users, [:plugin_bot], where: "plugin_bot IS NOT NULL")

    create table(:plugin_queue) do
      add :plugin_id, :string, null: false
      add :event, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :attempts, :integer, null: false, default: 0
      add :run_at, :utc_datetime_usec, null: false
      add :last_error, :text

      timestamps(type: :naive_datetime_usec)
    end

    create index(:plugin_queue, [:run_at])
    create index(:plugin_queue, [:plugin_id])

    create table(:plugin_schedules) do
      add :plugin_id, :string, null: false
      add :job, :string, null: false
      add :next_run_at, :utc_datetime_usec, null: false
    end

    create unique_index(:plugin_schedules, [:plugin_id, :job])
    create index(:plugin_schedules, [:next_run_at])

    create table(:plugin_kv) do
      add :plugin_id, :string, null: false
      add :key, :string, null: false
      add :value, :map, null: false
      add :size, :integer, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:plugin_kv, [:plugin_id, :key])

    create table(:plugin_fields) do
      add :plugin_id, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :bigint, null: false
      add :key, :string, null: false
      add :value, :map, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:plugin_fields, [:plugin_id, :target_type, :target_id, :key])
    create index(:plugin_fields, [:target_type, :target_id])
  end
end
