defmodule FirestormWeb.Repo.Migrations.CreatePluginEgressEntries do
  use Ecto.Migration

  # The plugin egress log (see FirestormWeb.Plugins.Egress): one row per
  # http.fetch a plugin attempted, sent or refused. Never bodies, headers or
  # query strings. Pruned after the plugin_egress_days site setting.
  def change do
    create table(:plugin_egress_entries) do
      add :plugin_id, :string, null: false
      add :method, :string, null: false
      add :host, :string
      add :path, :text
      add :status, :integer
      add :error, :string
      add :blocked, :boolean, null: false, default: false
      add :request_bytes, :integer, null: false, default: 0
      add :response_bytes, :integer, null: false, default: 0
      add :duration_ms, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:plugin_egress_entries, [:plugin_id, :inserted_at])
    create index(:plugin_egress_entries, [:inserted_at])
  end
end
