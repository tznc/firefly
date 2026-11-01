defmodule FirestormWeb.Repo.Migrations.NotificationLevels do
  use Ecto.Migration

  # Notification levels (watching / tracking / normal / muted) on threads and
  # categories, typed notifications with read state, and an email preference.
  def up do
    # Thread watches become levels. Existing rows were "watching".
    execute """
    DELETE FROM forums_threads_watches a USING forums_threads_watches b
    WHERE a.id > b.id AND a.assoc_id = b.assoc_id AND a.user_id = b.user_id
    """

    alter table(:forums_threads_watches) do
      add :level, :string, null: false, default: "watching"
    end

    create unique_index(:forums_threads_watches, [:user_id, :assoc_id])

    create table(:forums_categories_watches) do
      add :assoc_id, references(:forums_categories, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :level, :string, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_categories_watches, [:user_id, :assoc_id])

    alter table(:forums_notifications) do
      add :kind, :string, null: false, default: "new_post"
      add :thread_id, references(:forums_threads, on_delete: :delete_all)
      add :post_id, references(:forums_posts, on_delete: :delete_all)
      add :read_at, :utc_datetime
      add :emailed_at, :utc_datetime
    end

    create index(:forums_notifications, [:user_id, :read_at])

    alter table(:forums_users) do
      add :email_notifications, :boolean, null: false, default: true
    end
  end

  def down do
    alter table(:forums_users) do
      remove :email_notifications
    end

    drop index(:forums_notifications, [:user_id, :read_at])

    alter table(:forums_notifications) do
      remove :kind
      remove :thread_id
      remove :post_id
      remove :read_at
      remove :emailed_at
    end

    drop table(:forums_categories_watches)
    drop unique_index(:forums_threads_watches, [:user_id, :assoc_id])

    alter table(:forums_threads_watches) do
      remove :level
    end
  end
end
