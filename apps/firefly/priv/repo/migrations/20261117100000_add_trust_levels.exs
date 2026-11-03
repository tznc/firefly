defmodule Firefly.Repo.Migrations.AddTrustLevels do
  use Ecto.Migration

  # Trust levels (see Firefly.TrustLevels): 0 (new) to 4 (leader).
  # `manual_locked_trust_level` pins a level an admin chose, so the periodic
  # review leaves it alone; `trust_level_changed_at` dates the last change
  # (a new regular keeps the level for a grace period before review can
  # demote them).
  #
  # Each level has an automatic group (trust_level_0 to trust_level_4, a
  # role like any other, so categories can be restricted to it and it can
  # be @mentioned). A member is in the groups of their level and every level
  # below. A trigger keeps those memberships in step with `trust_level`,
  # whichever way an account is created or changed.
  #
  # `job_runs` records when each periodic job last ran (see
  # Firefly.JobRuns).
  def up do
    create table(:job_runs, primary_key: false) do
      add :name, :string, primary_key: true
      add :ran_at, :utc_datetime, null: false
    end

    alter table(:forums_users) do
      add :trust_level, :integer, null: false, default: 0
      add :manual_locked_trust_level, :integer
      add :trust_level_changed_at, :utc_datetime
    end

    # Confirmed members who have posted are past the new-user stage; the
    # first review promotes whoever has done more.
    execute """
    UPDATE forums_users u SET trust_level = 1
    WHERE u.confirmed_at IS NOT NULL AND u.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM forums_posts p WHERE p.user_id = u.id AND p.queued_at IS NULL)
    """

    execute """
    INSERT INTO forums_roles (name, visibility, membership, mentionable, messageable,
      inserted_at, updated_at)
    SELECT 'trust_level_' || n, 'staff', 'closed', 'nobody', 'nobody', now(), now()
    FROM generate_series(0, 4) AS n
    ON CONFLICT DO NOTHING
    """

    # Everyone now has memberships, so deleting an account takes them along.
    execute "ALTER TABLE forums_role_memberships DROP CONSTRAINT forums_role_memberships_user_id_fkey"

    alter table(:forums_role_memberships) do
      modify :user_id, references(:forums_users, on_delete: :delete_all)
    end

    execute """
    CREATE FUNCTION sync_trust_level_groups() RETURNS trigger AS $$
    BEGIN
      DELETE FROM forums_role_memberships m USING forums_roles r
      WHERE m.role_id = r.id AND m.user_id = NEW.id
        AND r.name ~ '^trust_level_[0-4]$' AND substr(r.name, 13)::int > NEW.trust_level;

      INSERT INTO forums_role_memberships (role_id, user_id, inserted_at, updated_at)
      SELECT r.id, NEW.id, now(), now() FROM forums_roles r
      WHERE r.name ~ '^trust_level_[0-4]$' AND substr(r.name, 13)::int <= NEW.trust_level
      ON CONFLICT (role_id, user_id) DO NOTHING;

      RETURN NULL;
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER forums_users_trust_level_groups
    AFTER INSERT OR UPDATE OF trust_level ON forums_users
    FOR EACH ROW WHEN (NEW.deleted_at IS NULL)
    EXECUTE FUNCTION sync_trust_level_groups()
    """

    execute """
    INSERT INTO forums_role_memberships (role_id, user_id, inserted_at, updated_at)
    SELECT r.id, u.id, now(), now() FROM forums_users u
    JOIN forums_roles r ON r.name ~ '^trust_level_[0-4]$' AND substr(r.name, 13)::int <= u.trust_level
    WHERE u.deleted_at IS NULL
    ON CONFLICT (role_id, user_id) DO NOTHING
    """
  end

  def down do
    execute "DROP TRIGGER forums_users_trust_level_groups ON forums_users"
    execute "DROP FUNCTION sync_trust_level_groups()"

    execute """
    DELETE FROM forums_role_memberships m USING forums_roles r
    WHERE m.role_id = r.id AND r.name ~ '^trust_level_[0-4]$'
    """

    execute "DELETE FROM forums_roles WHERE name ~ '^trust_level_[0-4]$'"

    execute "ALTER TABLE forums_role_memberships DROP CONSTRAINT forums_role_memberships_user_id_fkey"

    alter table(:forums_role_memberships) do
      modify :user_id, references(:forums_users)
    end

    alter table(:forums_users) do
      remove :trust_level
      remove :manual_locked_trust_level
      remove :trust_level_changed_at
    end

    drop table(:job_runs)
  end
end
