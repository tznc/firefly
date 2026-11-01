defmodule FirestormWeb.Repo.Migrations.SoftDeleteForumsPosts do
  use Ecto.Migration

  # Deleted replies keep their row so admins can review and restore them.
  def change do
    alter table(:forums_posts) do
      add :deleted_at, :utc_datetime
      add :deleted_by_id, references(:forums_users, on_delete: :nilify_all)
    end
  end
end
