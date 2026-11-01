defmodule FirestormWeb.Repo.Migrations.CreateForumsDrafts do
  use Ecto.Migration

  # Composer drafts, saved as the user types (see FirestormWeb.Drafts). One
  # per user per `key`: a new thread in a category, a reply to a thread or
  # an edit of a post. They go with what they're about.
  def change do
    create table(:forums_drafts) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :kind, :string, null: false
      add :category_id, references(:forums_categories, on_delete: :delete_all)
      add :thread_id, references(:forums_threads, on_delete: :delete_all)
      add :post_id, references(:forums_posts, on_delete: :delete_all)
      add :title, :string
      add :tags, :string
      add :body, :text

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_drafts, [:user_id, :key])
    create index(:forums_drafts, [:thread_id])
    create index(:forums_drafts, [:post_id])
    create index(:forums_drafts, [:category_id])
  end
end
