defmodule FirestormWeb.Repo.Migrations.CreateForumsBookmarks do
  use Ecto.Migration

  # Bookmarked posts (see FirestormWeb.Bookmarks): one per user per post,
  # with an optional note and reminder. A reminder's `remind_at` is cleared
  # when it fires, so the partial index holds just the pending ones.
  def change do
    create table(:forums_bookmarks) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :post_id, references(:forums_posts, on_delete: :delete_all), null: false
      add :note, :string, size: 500
      add :remind_at, :utc_datetime

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_bookmarks, [:user_id, :post_id])
    create index(:forums_bookmarks, [:post_id])
    create index(:forums_bookmarks, [:remind_at], where: "remind_at IS NOT NULL")
  end
end
