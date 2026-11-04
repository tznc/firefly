defmodule Firefly.Repo.Migrations.CreateThemes do
  use Ecto.Migration

  # Themes and theme components (see Firefly.Themes): color schemes, CSS,
  # head/header/footer HTML and assets, compiled into a versioned
  # stylesheet; the components each theme includes; and the theme a member
  # picked.
  def change do
    create table(:themes) do
      add :name, :string, null: false
      add :description, :text
      add :component, :boolean, null: false, default: false
      add :colors, :map, null: false, default: %{}
      add :css, :text, null: false, default: ""
      add :head_html, :text, null: false, default: ""
      add :header_html, :text, null: false, default: ""
      add :footer_html, :text, null: false, default: ""
      add :allow_scripts, :boolean, null: false, default: false
      add :user_selectable, :boolean, null: false, default: false
      add :version, :integer, null: false, default: 1
      add :compiled_css, :text, null: false, default: ""
      add :source_url, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:themes, ["lower(name)"], name: :themes_lower_name_index)

    create table(:theme_components, primary_key: false) do
      add :theme_id, references(:themes, on_delete: :delete_all), null: false
      add :component_id, references(:themes, on_delete: :delete_all), null: false
    end

    create unique_index(:theme_components, [:theme_id, :component_id])
    create index(:theme_components, [:component_id])

    create table(:theme_assets) do
      add :theme_id, references(:themes, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :upload_id, references(:uploads, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:theme_assets, [:theme_id, :name])

    alter table(:forums_users) do
      add :theme_id, references(:themes, on_delete: :nilify_all)
    end
  end
end
