defmodule FirestormWeb.Repo.Migrations.AddUserPreferences do
  use Ecto.Migration

  # Profile fields and per-user preferences (see /settings).
  def change do
    alter table(:forums_users) do
      add :bio, :text
      add :website, :string
      add :location, :string
      add :theme, :string, null: false, default: "system"
      add :reply_level, :string, null: false, default: "tracking"
      add :new_thread_level, :string, null: false, default: "watching"
      add :hide_profile_activity, :boolean, null: false, default: false
      add :hide_from_directory, :boolean, null: false, default: false
    end
  end
end
