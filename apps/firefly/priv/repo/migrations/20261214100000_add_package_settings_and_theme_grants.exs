defmodule Firefly.Repo.Migrations.AddPackageSettingsAndThemeGrants do
  use Ecto.Migration

  # A theme package's settings (exposed to its CSS as custom properties),
  # and the staff grant that lets a plugin's package ship theme components.
  def change do
    alter table(:packages) do
      add :settings, :map, null: false, default: %{}
      add :theme_granted_at, :utc_datetime
      add :theme_granted_by_id, references(:forums_users, on_delete: :nilify_all)
    end
  end
end
