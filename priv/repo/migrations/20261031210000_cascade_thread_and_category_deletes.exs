defmodule FirestormWeb.Repo.Migrations.CascadeThreadAndCategoryDeletes do
  use Ecto.Migration

  # Deleting a thread already deletes its posts, but post views and thread
  # watches blocked it; deleting a category was blocked by its threads.
  def change do
    alter table(:forums_posts_views) do
      modify :assoc_id, references(:forums_posts, on_delete: :delete_all),
        from: references(:forums_posts)
    end

    alter table(:forums_threads_watches) do
      modify :assoc_id, references(:forums_threads, on_delete: :delete_all),
        from: references(:forums_threads)
    end

    alter table(:forums_threads) do
      modify :category_id, references(:forums_categories, on_delete: :delete_all),
        from: references(:forums_categories, on_delete: :nothing)
    end
  end
end
