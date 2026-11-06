defmodule Firefly.Repo.Migrations.CreateBans do
  use Ecto.Migration

  # Banned addresses (see Firefly.Security.Jail).
  def change do
    create table(:bans) do
      add :ip, :string, size: 49, null: false
      add :jail, :string, null: false
      add :reason, :string
      add :offences, :integer, null: false, default: 1
      add :banned_until, :utc_datetime
      add :created_by_id, references(:forums_users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:bans, [:ip])
    create index(:bans, [:banned_until])
  end
end
