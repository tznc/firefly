defmodule Firefly.ControlTest do
  use Firefly.DataCase, async: true

  alias Firefly.Control
  alias Firefly.Control.{Hostname, Repo, Tenant}

  @url "postgres://firefly_t:s3cret-password@db.internal:5432/firefly_t_2"

  defp tenant_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, tenant} =
      Control.create_tenant(
        Map.merge(%{slug: "forum-#{n}", name: "Forum #{n}", database_url: @url}, attrs)
      )

    tenant
  end

  describe "the host tenant" do
    test "is tenant 1, active, on the host connection, created by the migration" do
      host = Control.host_tenant()
      assert host.id == Control.host_id()
      assert host.slug == "host"
      assert host.status == "active"
      assert host.database_url == nil
      assert host.pool_size == nil
      assert hd(Control.list_tenants()).id == 1
    end

    test "is the only tenant without a database URL" do
      assert {:error, changeset} = Control.create_tenant(%{slug: "nourl", name: "No URL"})

      assert "can't be blank (only the host uses the host connection)" in errors_on(changeset).database_url
    end

    test "new tenants get ids after it" do
      assert tenant_fixture().id > 1
    end
  end

  describe "tenants" do
    test "are created provisioning, and found by id and slug" do
      tenant = tenant_fixture(%{slug: "acme"})
      assert tenant.status == "provisioning"
      assert tenant.pool_size == 3
      assert Control.get_tenant(tenant.id).slug == "acme"
      assert Control.get_tenant_by_slug("acme").id == tenant.id
      assert Control.get_tenant_by_slug("nope") == nil
    end

    test "slugs are unique and well-formed, statuses known" do
      tenant_fixture(%{slug: "taken"})

      assert {:error, changeset} =
               Control.create_tenant(%{slug: "taken", name: "x", database_url: @url})

      assert "has already been taken" in errors_on(changeset).slug

      for slug <- ["Upper", "-dash", "under_score", "dash-"] do
        assert {:error, changeset} =
                 Control.create_tenant(%{slug: slug, name: "x", database_url: @url})

        assert errors_on(changeset).slug != []
      end

      assert {:error, changeset} = Control.update_tenant(tenant_fixture(), %{status: "gone"})
      assert "is invalid" in errors_on(changeset).status

      assert {:error, changeset} =
               Control.update_tenant(tenant_fixture(), %{database_url: "nope"})

      assert errors_on(changeset).database_url != []
    end

    test "database URLs are encrypted at rest and never shown" do
      tenant = tenant_fixture()

      %{rows: [[stored]]} =
        Repo.query!("SELECT database_url FROM control.tenants WHERE id = $1", [tenant.id])

      refute stored =~ "s3cret-password"
      assert Firefly.Vault.decrypt!(stored) == @url
      assert Control.get_tenant(tenant.id).database_url == @url
      refute inspect(Control.get_tenant(tenant.id)) =~ "s3cret-password"

      new_url = "postgres://u:other@db2.internal/firefly_t_2"
      {:ok, _} = Control.update_tenant(tenant, %{database_url: new_url})
      assert Control.get_tenant(tenant.id).database_url == new_url
    end
  end

  describe "migrations" do
    test "the control set is its own, never the forum's" do
      path = Firefly.Control.Migrator.migrations_path()
      assert Ecto.Migrator.migrations_path(Repo) == path
      refute path == Ecto.Migrator.migrations_path(Firefly.Repo)

      for file <- Path.wildcard(Path.join(path, "*.exs")) do
        assert File.read!(file) =~ "defmodule Firefly.Control.Repo.Migrations."
      end

      # Recorded in the control schema's own version table.
      assert %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM control.schema_migrations")
      assert n == length(Path.wildcard(Path.join(path, "*.exs")))
    end

    test "control tables exist only in the control schema" do
      %{rows: rows} =
        Repo.query!("""
        SELECT table_schema FROM information_schema.tables
        WHERE table_name IN ('tenants', 'tenant_hostnames')
        """)

      assert Enum.uniq(rows) == [["control"]]
    end
  end

  describe "hostnames" do
    test "are stored normalized and unique across tenants" do
      a = tenant_fixture()
      b = tenant_fixture()

      assert {:ok, %Hostname{hostname: "forum.example.com"}} =
               Control.create_hostname(a, %{hostname: " Forum.Example.COM.:443 "})

      assert {:error, changeset} = Control.create_hostname(b, %{hostname: "FORUM.example.com"})
      assert "has already been taken" in errors_on(changeset).hostname

      assert {:error, changeset} = Control.create_hostname(b, %{hostname: "not a host!"})
      assert errors_on(changeset).hostname != []
    end

    test "find their tenant, whatever the case or port" do
      tenant = tenant_fixture()
      {:ok, _} = Control.create_hostname(tenant, %{hostname: "community.example.org"})

      assert Control.get_tenant_by_host("Community.Example.org:4000").id == tenant.id
      assert Control.get_tenant_by_host("other.example.org") == nil
    end

    test "a tenant has at most one primary, and making one primary moves it" do
      tenant = tenant_fixture()

      {:ok, first} =
        Control.create_hostname(tenant, %{hostname: "one.example.com", primary: true})

      {:ok, second} =
        Control.create_hostname(tenant, %{hostname: "two.example.com", primary: true})

      refute Repo.reload!(first).primary
      assert second.primary

      assert [%{hostname: "two.example.com", primary: true}, %{primary: false}] =
               Control.get_tenant!(tenant.id).hostnames

      {:ok, _} = Control.update_hostname(Repo.reload!(first), %{primary: true})
      assert [%{hostname: "one.example.com"}, _] = Control.get_tenant!(tenant.id).hostnames

      # The database refuses two primaries even without the context.
      assert_raise Postgrex.Error, ~r/one_primary/, fn ->
        Repo.update_all(Ecto.Query.from(h in Hostname, where: h.tenant_id == ^tenant.id),
          set: [primary: true]
        )
      end
    end

    test "go with their tenant" do
      tenant = tenant_fixture()
      {:ok, _} = Control.create_hostname(tenant, %{hostname: "gone.example.com"})
      Repo.delete!(%Tenant{id: tenant.id})
      assert Control.get_tenant_by_host("gone.example.com") == nil
      assert Repo.aggregate(Hostname, :count) == 0
    end
  end
end
