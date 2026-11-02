defmodule FirestormWeb.Repo.Migrations.CreateLinkPreviews do
  use Ecto.Migration

  # Link previews (see FirestormWeb.LinkPreviews): what a page's OpenGraph
  # and Twitter card tags said, cached by URL until `expires_at`.
  def change do
    create table(:link_previews) do
      add :url_hash, :string, null: false
      add :url, :text, null: false
      add :status, :string, null: false
      add :title, :text
      add :description, :text
      add :site_name, :text
      add :image_upload_id, references(:uploads, on_delete: :nilify_all)
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:link_previews, [:url_hash])
    create index(:link_previews, [:expires_at])
  end
end
