defmodule FirestormWeb.Repo.Migrations.CreateForumsThreadReads do
  use Ecto.Migration

  # Per-user, per-thread read position: the newest post the user has seen.
  # Replaces deriving read state from one forums_posts_views row per post.
  def up do
    create table(:forums_thread_reads) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :thread_id, references(:forums_threads, on_delete: :delete_all), null: false
      add :last_read_post_id, :bigint, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_thread_reads, [:user_id, :thread_id])
    create index(:forums_thread_reads, [:thread_id])

    flush()

    execute """
    INSERT INTO forums_thread_reads (user_id, thread_id, last_read_post_id, inserted_at, updated_at)
    SELECT v.user_id, p.thread_id, max(p.id), now(), now()
    FROM forums_posts_views v
    JOIN forums_posts p ON p.id = v.assoc_id
    JOIN forums_users u ON u.id = v.user_id
    GROUP BY v.user_id, p.thread_id
    """
  end

  def down do
    drop table(:forums_thread_reads)
  end
end
