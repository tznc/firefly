defmodule FirestormWeb.Repo.Migrations.CreatePlugins do
  use Ecto.Migration

  # Installed plugins (see FirestormWeb.Plugins). Uploaded plugins keep
  # their bundle here, so every node loads them from the database; core
  # plugins (Elixir modules from config) get a row once staff change their
  # state or settings.
  def change do
    create table(:plugins) do
      add :plugin_id, :string, null: false
      add :source, :string, null: false
      add :version, :string, null: false
      add :manifest, :map
      add :bundle, :binary
      add :checksum, :string
      add :code, :text
      add :enabled, :boolean, null: false, default: false
      add :disabled_reason, :text
      add :settings, :map, null: false, default: %{}
      add :installed_by_id, references(:forums_users, on_delete: :nilify_all)

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:plugins, [:plugin_id])

    # The per-plugin error log. Keyed by plugin id, not row: a core plugin
    # may have no row, and the log outlives an uninstall's row until it's
    # cleared with it.
    create table(:plugin_errors) do
      add :plugin_id, :string, null: false
      add :hook, :string, null: false
      add :kind, :string, null: false
      add :message, :text, null: false

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create index(:plugin_errors, [:plugin_id, :id])
  end
end
