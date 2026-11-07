defmodule Firefly.Repo.Migrations.CreateUserSessions do
  use Ecto.Migration

  # Server-side sessions (see Firefly.Accounts.UserSessions).
  def change do
    create table(:user_sessions) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :remember, :boolean, null: false, default: false
      add :ip, :string, size: 45
      add :user_agent, :string, size: 512
      add :device, :string
      add :last_seen_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:user_sessions, [:token_hash])
    create index(:user_sessions, [:user_id, :last_seen_at])
    create index(:user_sessions, [:last_seen_at])
  end
end
