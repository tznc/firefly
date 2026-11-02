defmodule Firefly.Repo.Migrations.ExtendGroups do
  use Ecto.Migration

  # Groups (forums_roles) get pages, membership modes, owners, @mentions and
  # inboxes (see Firefly.Groups). Existing groups stay as they were:
  # visible to staff only, closed, not mentionable or messageable.
  def up do
    alter table(:forums_roles) do
      add :description, :text
      add :visibility, :string, null: false, default: "staff"
      add :membership, :string, null: false, default: "closed"
      add :mentionable, :string, null: false, default: "nobody"
      add :messageable, :string, null: false, default: "nobody"
    end

    create unique_index(:forums_roles, ["lower(name)"], name: :forums_roles_lower_name_index)

    # Memberships were never unique; keep the first of any duplicates.
    execute """
    DELETE FROM forums_role_memberships m USING forums_role_memberships d
    WHERE m.role_id = d.role_id AND m.user_id = d.user_id AND m.id > d.id
    """

    alter table(:forums_role_memberships) do
      add :owner, :boolean, null: false, default: false
      # How the member hears about messages to the group's inbox.
      add :notification_level, :string, null: false, default: "watching"
    end

    create unique_index(:forums_role_memberships, [:role_id, :user_id])

    # Requests to join (by the user) and invitations (by an owner).
    create table(:group_requests) do
      add :role_id, references(:forums_roles, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :message, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:group_requests, [:role_id, :user_id])
    create index(:group_requests, [:user_id])

    # A conversation addressed to a group: its members can read and reply.
    alter table(:forums_conversations) do
      add :role_id, references(:forums_roles, on_delete: :nilify_all)
    end

    create index(:forums_conversations, [:role_id])
  end

  def down do
    alter table(:forums_conversations), do: remove(:role_id)
    drop table(:group_requests)
    drop unique_index(:forums_role_memberships, [:role_id, :user_id])

    alter table(:forums_role_memberships) do
      remove :owner
      remove :notification_level
    end

    drop index(:forums_roles, [], name: :forums_roles_lower_name_index)

    alter table(:forums_roles) do
      remove :description
      remove :visibility
      remove :membership
      remove :mentionable
      remove :messageable
    end
  end
end
