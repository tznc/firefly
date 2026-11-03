defmodule Firefly.Repo.Migrations.CreateInvites do
  use Ecto.Migration

  # Invitations to join (see Firefly.Accounts.Invites): to an email
  # address, or a link for up to `max_uses` people, and who redeemed them.
  def change do
    create table(:invites) do
      add :key, :string, null: false
      add :invited_by_id, references(:forums_users, on_delete: :delete_all), null: false
      add :email, :string
      add :domain, :string
      add :max_uses, :integer, null: false, default: 1
      add :uses, :integer, null: false, default: 0
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      add :emailed_at, :utc_datetime
      add :role_id, references(:forums_roles, on_delete: :nilify_all)
      add :thread_id, references(:forums_threads, on_delete: :nilify_all)

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:invites, [:key])
    create index(:invites, [:invited_by_id])

    create table(:invite_redemptions) do
      add :invite_id, references(:invites, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create unique_index(:invite_redemptions, [:invite_id, :user_id])
  end
end
