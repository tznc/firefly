defmodule Firefly.Repo.Migrations.CreateUserIdentities do
  use Ecto.Migration

  # Accounts at login providers (GitHub, Google, ...) linked to users, by the
  # provider's immutable id (see Firefly.Auth). Replaces
  # forums_users.github_uid, whose links move here.
  def up do
    create table(:user_identities) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :uid, :string, null: false
      add :info, :map, null: false, default: %{}

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:user_identities, [:provider, :uid])
    create unique_index(:user_identities, [:user_id, :provider])

    execute """
    INSERT INTO user_identities (user_id, provider, uid, info, inserted_at, updated_at)
    SELECT id, 'github', github_uid, jsonb_build_object('nickname', username), now(), now()
    FROM forums_users WHERE github_uid IS NOT NULL
    """

    alter table(:forums_users) do
      remove :github_uid
    end
  end

  def down do
    alter table(:forums_users) do
      add :github_uid, :string
    end

    create unique_index(:forums_users, [:github_uid])

    execute """
    UPDATE forums_users u SET github_uid = i.uid
    FROM user_identities i WHERE i.user_id = u.id AND i.provider = 'github'
    """

    drop table(:user_identities)
  end
end
