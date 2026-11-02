defmodule FirestormWeb.Repo.Migrations.CreateUploads do
  use Ecto.Migration

  # Files members upload (see FirestormWeb.Uploads). The stored file is
  # named by its sha256, so identical content is kept once however often
  # it's uploaded; each upload row says who uploaded it and what it's
  # attached to (a post or message, or the uploader's avatar). Uploads
  # attached to nothing are removed after a grace period.
  def change do
    create table(:uploads) do
      add :token, :string, null: false
      add :user_id, references(:forums_users, on_delete: :nilify_all)
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :size, :bigint, null: false
      add :sha256, :string, null: false
      add :width, :integer
      add :height, :integer
      add :thumbnail, :boolean, null: false, default: false
      add :attached_to, :string
      add :post_id, references(:forums_posts, on_delete: :nilify_all)
      add :message_id, references(:forums_messages, on_delete: :nilify_all)
      add :attached_at, :utc_datetime

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:uploads, [:token])
    create index(:uploads, [:user_id, :sha256])
    create index(:uploads, [:sha256])
    create index(:uploads, [:post_id])
    create index(:uploads, [:message_id])
    create index(:uploads, [:inserted_at], where: "attached_to IS NULL")

    alter table(:forums_users) do
      add :avatar_upload_id, references(:uploads, on_delete: :nilify_all)
    end
  end
end
