defmodule Firefly.Repo.Migrations.CreateVersionChecks do
  use Ecto.Migration

  # The latest release found by the daily version check (see
  # Firefly.Upgrades): one row.
  def change do
    create table(:version_checks) do
      add :etag, :string
      add :latest_version, :string
      add :release_name, :string
      add :release_notes, :text
      add :release_url, :string, size: 2000
      add :published_at, :utc_datetime
      add :checked_at, :utc_datetime
      add :error, :string, size: 1000
      add :notified_version, :string
    end
  end
end
