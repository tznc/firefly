defmodule Firefly.Repo.Migrations.CreateSecurityEvents do
  use Ecto.Migration

  # The security log (see Firefly.Security).
  def change do
    create table(:security_events) do
      add :kind, :string, null: false
      add :user_id, references(:forums_users, on_delete: :delete_all)
      add :ip, :string, size: 45
      add :user_agent, :string, size: 512
      add :details, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:security_events, [:user_id, :inserted_at])
    create index(:security_events, [:inserted_at])
    create index(:security_events, [:kind, :inserted_at])
    create index(:security_events, [:ip])
  end
end
