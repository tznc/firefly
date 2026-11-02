defmodule FirestormWeb.Repo.Migrations.AddPluginModeration do
  use Ecto.Migration

  # Why a post waits in the review queue when a plugin sent it there, and
  # whether a plugin's moderation failing blocks posting (fail closed) or
  # not (fail open, the default).
  def change do
    alter table(:forums_posts) do
      add :queued_reason, :text
    end

    alter table(:plugins) do
      add :fail_closed, :boolean, null: false, default: false
    end
  end
end
