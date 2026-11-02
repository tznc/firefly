defmodule Firefly.Repo.Migrations.AddProfileBackgroundsAndHideProfile do
  use Ecto.Migration

  # Uploaded backgrounds for the profile page and the user card, and the
  # "hide my public profile and presence" preference (see Firefly.Profiles).
  def change do
    alter table(:forums_users) do
      add :profile_background_upload_id, references(:uploads, on_delete: :nilify_all)
      add :card_background_upload_id, references(:uploads, on_delete: :nilify_all)
      add :hide_profile, :boolean, null: false, default: false
    end
  end
end
