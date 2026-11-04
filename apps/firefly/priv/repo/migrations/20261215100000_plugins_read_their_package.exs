defmodule Firefly.Repo.Migrations.PluginsReadTheirPackage do
  use Ecto.Migration

  # An uploaded plugin's zip and checksum live on its package only (see
  # Firefly.Packages); the plugin row points at it. Core plugins have none.
  def up do
    alter table(:plugins) do
      add :package_id, references(:packages, on_delete: :restrict)
    end

    execute("""
    UPDATE plugins SET package_id = packages.id
    FROM packages WHERE packages.package_id = plugins.plugin_id AND plugins.source = 'upload'
    """)

    # Every uploaded plugin's zip must be on a package before it goes.
    execute("""
    DO $$
    DECLARE orphans text;
    BEGIN
      SELECT string_agg(plugin_id, ', ') INTO orphans
      FROM plugins WHERE source = 'upload' AND package_id IS NULL;

      IF orphans IS NOT NULL THEN
        RAISE EXCEPTION 'Uploaded plugins without a package (their zip would be lost): %', orphans;
      END IF;
    END $$;
    """)

    create unique_index(:plugins, [:package_id])

    alter table(:plugins) do
      remove :bundle
      remove :checksum
    end
  end

  def down do
    alter table(:plugins) do
      add :bundle, :binary
      add :checksum, :string
    end

    execute("""
    UPDATE plugins SET bundle = packages.archive, checksum = packages.checksum
    FROM packages WHERE packages.id = plugins.package_id
    """)

    drop unique_index(:plugins, [:package_id])

    alter table(:plugins) do
      remove :package_id
    end
  end
end
