defmodule Firefly.Control do
  @moduledoc """
  The Control context: the server's registry of tenants (forums), in the
  host database's `control` schema (see `docs/multitenancy.md`).

  The host database holds two schemas: `control`, reached only through
  `Firefly.Control.Repo`, and `public`, the forum data of tenant 1, the
  host itself. Tenant 1 (`host_id/0`, slug `host`) is created by the first
  control migration, so every install has it; its `database_url` is nil,
  meaning "the host connection". Every other tenant has its own database,
  whose URL is stored encrypted (`Firefly.Vault`).

  Tenants have hostnames (`Firefly.Control.Hostname`): unique across the
  server, lowercase, one of them the primary.

  This is internal API for the rest of the domain; the management API
  comes later.
  """

  use Boundary, top_level?: true, check: [out: false], exports: [Repo, Tenant, Hostname]

  import Ecto.Query

  alias Firefly.Control.{Hostname, Repo, Tenant}

  @host_id 1

  @doc """
  Runs the pending control migrations on the host database's `control`
  schema (see `Firefly.Control.Migrator`).
  """
  @spec migrate(keyword) :: [integer]
  defdelegate migrate(opts \\ []), to: Firefly.Control.Migrator

  @doc "Tenant 1's id: the host database's own forum."
  @spec host_id() :: pos_integer
  def host_id, do: @host_id

  @doc "Tenant 1, the host."
  @spec host_tenant() :: Tenant.t()
  def host_tenant, do: get_tenant!(@host_id)

  @doc "Every tenant, by id, with its hostnames."
  @spec list_tenants() :: [Tenant.t()]
  def list_tenants,
    do: Repo.all(from(t in Tenant, order_by: t.id, preload: ^hostnames_preload()))

  @doc "The tenant with `id` (with its hostnames), or nil."
  @spec get_tenant(integer) :: Tenant.t() | nil
  def get_tenant(id),
    do: Repo.one(from(t in Tenant, where: t.id == ^id, preload: ^hostnames_preload()))

  @doc "Like `get_tenant/1`, raising when there is none."
  @spec get_tenant!(integer) :: Tenant.t()
  def get_tenant!(id),
    do: Repo.one!(from(t in Tenant, where: t.id == ^id, preload: ^hostnames_preload()))

  @doc "The tenant with `slug`, or nil."
  @spec get_tenant_by_slug(String.t()) :: Tenant.t() | nil
  def get_tenant_by_slug(slug) when is_binary(slug),
    do: Repo.one(from(t in Tenant, where: t.slug == ^slug, preload: ^hostnames_preload()))

  @doc """
  The tenant serving `host` (any case, with or without a port or a
  trailing dot), or nil.
  """
  @spec get_tenant_by_host(String.t()) :: Tenant.t() | nil
  def get_tenant_by_host(host) when is_binary(host) do
    Repo.one(
      from(t in Tenant,
        join: h in assoc(t, :hostnames),
        where: h.hostname == ^Hostname.normalize(host),
        preload: ^hostnames_preload()
      )
    )
  end

  @doc "Registers a tenant (status `provisioning` unless given)."
  @spec create_tenant(map) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def create_tenant(attrs) do
    with {:ok, tenant} <- %Tenant{} |> Tenant.changeset(attrs) |> Repo.insert() do
      {:ok, Repo.preload(tenant, hostnames: [])}
    end
  end

  @doc "Changes a tenant's name, status, database URL or pool size."
  @spec update_tenant(Tenant.t(), map) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def update_tenant(%Tenant{} = tenant, attrs),
    do: tenant |> Tenant.changeset(attrs) |> Repo.update()

  @doc """
  Adds a hostname to `tenant`. Making it `primary` unmarks the tenant's
  other primary hostname.
  """
  @spec create_hostname(Tenant.t(), map) :: {:ok, Hostname.t()} | {:error, Ecto.Changeset.t()}
  def create_hostname(%Tenant{id: tenant_id}, attrs) do
    %Hostname{tenant_id: tenant_id}
    |> Hostname.changeset(attrs)
    |> save_hostname()
  end

  @doc "Changes a hostname (its name, or whether it's the primary)."
  @spec update_hostname(Hostname.t(), map) :: {:ok, Hostname.t()} | {:error, Ecto.Changeset.t()}
  def update_hostname(%Hostname{} = hostname, attrs),
    do: hostname |> Hostname.changeset(attrs) |> save_hostname()

  defp save_hostname(changeset) do
    Repo.transact(fn ->
      if Ecto.Changeset.get_change(changeset, :primary) == true do
        tenant_id = Ecto.Changeset.get_field(changeset, :tenant_id)

        Repo.update_all(
          from(h in Hostname, where: h.tenant_id == ^tenant_id and h.primary),
          set: [primary: false]
        )
      end

      Repo.insert_or_update(changeset)
    end)
  end

  defp hostnames_preload,
    do: [hostnames: from(h in Hostname, order_by: [desc: h.primary, asc: h.hostname])]
end
