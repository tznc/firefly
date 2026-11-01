defmodule FirestormWeb.Repo.Migrations.CreateForumsPostLikes do
  use Ecto.Migration

  # One like per user per post.
  def change do
    create table(:forums_post_likes) do
      add :post_id, references(:forums_posts, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create unique_index(:forums_post_likes, [:post_id, :user_id])
    create index(:forums_post_likes, [:user_id])
  end
end
