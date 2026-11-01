defmodule FirestormWeb.Repo.Migrations.CreateForumsPostRevisions do
  use Ecto.Migration

  # Post editing: each edit stores the body it replaced, and the post records
  # when it was last edited (for the "edited" indicator).
  def change do
    alter table(:forums_posts) do
      add :edited_at, :naive_datetime_usec
    end

    create table(:forums_post_revisions) do
      add :post_id, references(:forums_posts, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :nilify_all)
      add :body, :text, null: false

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create index(:forums_post_revisions, [:post_id])
  end
end
