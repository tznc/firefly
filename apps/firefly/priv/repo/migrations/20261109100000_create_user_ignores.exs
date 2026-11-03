defmodule Firefly.Repo.Migrations.CreateUserIgnores do
  use Ecto.Migration

  # Users a member muted (no notifications from them) or ignored (also their
  # posts collapsed, their threads hidden, no messages from them); see
  # Firefly.Ignores. An ignore may expire.
  def change do
    create table(:user_ignores) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :ignored_user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :level, :string, null: false
      add :expires_at, :utc_datetime

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:user_ignores, [:user_id, :ignored_user_id])
    create index(:user_ignores, [:ignored_user_id])
  end
end
