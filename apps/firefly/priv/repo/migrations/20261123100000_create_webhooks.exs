defmodule Firefly.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  # Outbound webhooks (see Firefly.Webhooks) and their delivery log, which
  # is also the delivery queue.
  def change do
    create table(:webhooks) do
      add :payload_url, :string, size: 2000, null: false
      add :secret, :binary
      add :content_type, :string, null: false, default: "application/json"
      add :wildcard, :boolean, null: false, default: false
      add :event_types, {:array, :string}, null: false, default: []
      add :category_ids, {:array, :bigint}, null: false, default: []
      add :tag_names, {:array, :string}, null: false, default: []
      add :group_ids, {:array, :bigint}, null: false, default: []
      add :active, :boolean, null: false, default: true
      add :failure_count, :integer, null: false, default: 0
      add :last_status, :string
      add :last_delivery_at, :utc_datetime

      timestamps(type: :naive_datetime_usec)
    end

    create table(:webhook_deliveries) do
      add :webhook_id, references(:webhooks, on_delete: :delete_all), null: false
      add :event_id, :uuid, null: false
      add :event, :string, null: false
      add :payload, :map, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :run_at, :utc_datetime_usec, null: false
      add :request_headers, :map
      add :request_body, :text
      add :response_status, :integer
      add :response_headers, :map
      add :response_body, :text
      add :error, :text
      add :duration_ms, :integer
      add :delivered_at, :utc_datetime

      timestamps(type: :naive_datetime_usec)
    end

    create index(:webhook_deliveries, [:webhook_id, :id])
    create index(:webhook_deliveries, [:run_at], where: "status = 'pending'")
  end
end
