defmodule Firefly.Control.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  # The server's tenants (forums) and their hostnames, in the host
  # database's `control` schema (see Firefly.Control). Tenant 1 is the host
  # itself: its forum is the host database's `public` schema, so it alone
  # has no database URL (the others' are encrypted by Firefly.Vault).
  def change do
    create table(:tenants, prefix: "control") do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "provisioning"
      add :database_url, :binary
      add :pool_size, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenants, [:slug], prefix: "control")

    create constraint(:tenants, :status_known,
             check: "status IN ('provisioning', 'active', 'suspended', 'deleted')",
             prefix: "control"
           )

    create constraint(:tenants, :database_url_set,
             check: "database_url IS NOT NULL OR id = 1",
             prefix: "control"
           )

    create table(:tenant_hostnames, prefix: "control") do
      add :tenant_id, references(:tenants, on_delete: :delete_all, prefix: "control"),
        null: false

      add :hostname, :string, null: false
      add :primary, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenant_hostnames, [:hostname], prefix: "control")
    create index(:tenant_hostnames, [:tenant_id], prefix: "control")

    create unique_index(:tenant_hostnames, [:tenant_id],
             where: "\"primary\"",
             name: :tenant_hostnames_one_primary_index,
             prefix: "control"
           )

    execute(
      """
      INSERT INTO control.tenants (id, slug, name, status, inserted_at, updated_at)
      VALUES (1, 'host', 'Host', 'active', now(), now())
      """,
      ""
    )

    execute("SELECT setval(pg_get_serial_sequence('control.tenants', 'id'), 1)", "")
  end
end
