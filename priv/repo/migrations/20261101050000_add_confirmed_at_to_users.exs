defmodule FirestormWeb.Repo.Migrations.AddConfirmedAtToUsers do
  use Ecto.Migration

  # Email confirmation. Accounts that predate it count as confirmed.
  def up do
    alter table(:forums_users) do
      add :confirmed_at, :utc_datetime
    end

    flush()
    execute "UPDATE forums_users SET confirmed_at = now()"
  end

  def down do
    alter table(:forums_users) do
      remove :confirmed_at
    end
  end
end
