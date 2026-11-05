defmodule Firefly.Repo.Migrations.MovePluginEventsAndWebhooksToOban do
  @moduledoc """
  Plugin events and webhook deliveries are Oban jobs now (see
  Firefly.Plugins.EventWorker and Firefly.Webhooks.DeliveryWorker). Queued
  plugin events become jobs, keeping their attempts and next run, and
  their table goes; pending webhook deliveries keep their rows (the
  delivery log) and get a job each. Down puts waiting plugin events back
  in their table and drops the webhook jobs (their rows are still pending,
  for the old poller).
  """
  use Ecto.Migration

  @event_worker "Firefly.Plugins.EventWorker"
  @delivery_worker "Firefly.Webhooks.DeliveryWorker"
  @waiting "('available', 'scheduled', 'retryable')"

  def up do
    execute("""
    INSERT INTO oban_jobs (state, queue, worker, args, attempt, max_attempts, scheduled_at, inserted_at)
    SELECT 'scheduled', 'plugins', '#{@event_worker}',
           jsonb_build_object('plugin_id', plugin_id, 'event', event, 'payload', payload),
           attempts, 5, run_at, inserted_at
    FROM plugin_queue
    """)

    execute("""
    INSERT INTO oban_jobs (state, queue, worker, args, attempt, max_attempts, scheduled_at, inserted_at)
    SELECT 'scheduled', 'webhooks', '#{@delivery_worker}',
           jsonb_build_object('delivery_id', id), attempts, 5, run_at, inserted_at
    FROM webhook_deliveries
    WHERE status = 'pending'
    """)

    drop table(:plugin_queue)
  end

  def down do
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

    execute("""
    INSERT INTO plugin_queue (plugin_id, event, payload, attempts, run_at, inserted_at, updated_at)
    SELECT args->>'plugin_id', args->>'event', COALESCE(args->'payload', '{}'::jsonb),
           attempt, scheduled_at, inserted_at, now()
    FROM oban_jobs
    WHERE worker = '#{@event_worker}' AND state IN #{@waiting}
    """)

    execute("DELETE FROM oban_jobs WHERE worker IN ('#{@event_worker}', '#{@delivery_worker}')")
  end
end
