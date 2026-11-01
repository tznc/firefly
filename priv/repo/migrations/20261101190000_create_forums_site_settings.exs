defmodule FirestormWeb.Repo.Migrations.CreateForumsSiteSettings do
  use Ecto.Migration

  # Only settings an admin changed have a row; the rest use their defaults
  # (see FirestormWeb.SiteSettings), which match the site's prior behavior.
  def change do
    create table(:forums_site_settings) do
      add :key, :string, null: false
      add :value, :text, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_site_settings, [:key])
  end
end
