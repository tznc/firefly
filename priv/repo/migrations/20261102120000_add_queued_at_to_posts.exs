defmodule FirestormWeb.Repo.Migrations.AddQueuedAtToPosts do
  use Ecto.Migration

  # Set while a new user's post waits for staff approval (see
  # FirestormWeb.Review); a thread is queued with its first post.
  def change do
    alter table(:forums_posts) do
      add :queued_at, :utc_datetime
    end

    create index(:forums_posts, [:queued_at], where: "queued_at IS NOT NULL")
    # For the lists' check for threads whose first post is queued.
    create index(:forums_posts, [:thread_id],
             where: "queued_at IS NOT NULL",
             name: :forums_posts_queued_thread_id_index
           )

    create index(:forums_post_flags, [:post_id],
             where: "status = 'pending'",
             name: :forums_post_flags_pending_index
           )
  end
end
