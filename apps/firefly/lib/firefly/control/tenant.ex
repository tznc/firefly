defmodule Firefly.Control.Tenant do
  @moduledoc """
  A forum the server hosts (see `Firefly.Control`): its `slug`, `name`,
  `status` (`provisioning`, `active`, `suspended`, `deleted`), the URL of
  its database (`database_url`, encrypted at rest by `Firefly.Vault`; nil
  only for tenant 1, the host, whose forum is the host database's own
  `public` schema) and how many connections each node opens to it
  (`pool_size`; nil: the host connection's).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @schema_prefix "control"
  @statuses ~w(provisioning active suspended deleted)

  schema "tenants" do
    field(:slug, :string)
    field(:name, :string)
    field(:status, :string, default: "provisioning")
    field(:database_url, Firefly.Encrypted.Binary, redact: true)
    field(:pool_size, :integer, default: 3)
    has_many(:hostnames, Firefly.Control.Hostname)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The statuses a tenant can have."
  def statuses, do: @statuses

  @doc false
  def changeset(%__MODULE__{} = tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name, :status, :database_url, :pool_size])
    |> validate_required([:slug, :name, :status])
    |> validate_format(:slug, ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/,
      message: "must be lowercase letters, digits and dashes"
    )
    |> validate_length(:name, max: 200)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:pool_size, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_change(:database_url, &url_errors/2)
    |> unique_constraint(:slug)
    |> check_constraint(:database_url,
      name: :database_url_set,
      message: "can't be blank (only the host uses the host connection)"
    )
  end

  defp url_errors(:database_url, url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ~w(ecto postgres postgresql) and host not in [nil, ""] ->
        []

      _ ->
        [database_url: "must be a postgres:// or ecto:// URL"]
    end
  end
end
