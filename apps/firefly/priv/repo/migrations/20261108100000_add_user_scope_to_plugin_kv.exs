defmodule Firefly.Repo.Migrations.AddUserScopeToPluginKv do
  use Ecto.Migration

  # Plugin storage gets a per-user scope (see Firefly.Plugins.Storage):
  # rows with a user_id are that member's, the rest stay plugin-global. One
  # unique index covers both scopes; NULLS NOT DISTINCT keeps a global key
  # unique too.
  def up do
    alter table(:plugin_kv) do
      add :user_id, references(:forums_users, on_delete: :delete_all)
    end

    drop unique_index(:plugin_kv, [:plugin_id, :key])
    create unique_index(:plugin_kv, [:plugin_id, :user_id, :key], nulls_distinct: false)
    # Account export and deletion find a member's rows across plugins.
    create index(:plugin_kv, [:user_id], where: "user_id IS NOT NULL")
  end

  # Rolling back drops every member's plugin data: without the column it
  # would collide with the global keys.
  def down do
    execute "DELETE FROM plugin_kv WHERE user_id IS NOT NULL"
    drop index(:plugin_kv, [:user_id], where: "user_id IS NOT NULL")
    drop unique_index(:plugin_kv, [:plugin_id, :user_id, :key])

    alter table(:plugin_kv) do
      remove :user_id
    end

    create unique_index(:plugin_kv, [:plugin_id, :key])
  end
end
