defmodule Firefly.Repo.Migrations.CreatePackages do
  use Ecto.Migration

  # Packages (see Firefly.Packages): every plugin and theme uploaded or
  # fetched, with the archive it came in. Themes a package installed point
  # to it, with a hash of what it set, to tell local edits apart.
  def up do
    create table(:packages) do
      add :package_id, :string, null: false
      add :name, :string, null: false
      add :version, :string, null: false
      add :tags, {:array, :string}, null: false, default: []
      add :manifest, :map, null: false
      add :archive, :binary, null: false
      add :checksum, :string, null: false
      add :source_url, :text
      add :installed_by_id, references(:forums_users, on_delete: :nilify_all)

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:packages, [:package_id])

    alter table(:themes) do
      add :package_id, references(:packages, on_delete: :nilify_all)
      add :package_key, :string
      add :package_hash, :string
    end

    create unique_index(:themes, [:package_id, :package_key])

    # The plugins uploaded so far are packages too.
    execute("""
    INSERT INTO packages (package_id, name, version, tags, manifest, archive, checksum,
                          installed_by_id, inserted_at, updated_at)
    SELECT plugin_id, coalesce(manifest->>'name', plugin_id), version, '{}', manifest, bundle,
           checksum, installed_by_id, inserted_at, updated_at
    FROM plugins
    WHERE source = 'upload' AND bundle IS NOT NULL AND manifest IS NOT NULL
      AND checksum IS NOT NULL
    """)
  end

  def down do
    drop unique_index(:themes, [:package_id, :package_key])

    alter table(:themes) do
      remove :package_id
      remove :package_key
      remove :package_hash
    end

    drop table(:packages)
  end
end
