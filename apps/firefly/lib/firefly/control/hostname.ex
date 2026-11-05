defmodule Firefly.Control.Hostname do
  @moduledoc """
  A hostname a tenant is served on (see `Firefly.Control`): unique across
  the server, stored lowercase without a port or trailing dot, and at most
  one `primary` per tenant (the one its links use).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @schema_prefix "control"

  schema "tenant_hostnames" do
    field(:hostname, :string)
    field(:primary, :boolean, default: false)
    belongs_to(:tenant, Firefly.Control.Tenant)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  `host` as stored: trimmed, lowercase, without a port or a trailing dot.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/:\d+\z/, "")
    |> String.trim_trailing(".")
  end

  @doc false
  def changeset(%__MODULE__{} = hostname, attrs) do
    hostname
    |> cast(attrs, [:hostname, :primary])
    |> update_change(:hostname, &normalize/1)
    |> validate_required([:hostname, :tenant_id])
    |> validate_length(:hostname, max: 253)
    |> validate_format(
      :hostname,
      ~r/\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/,
      message: "must be a hostname (letters, digits, dashes and dots)"
    )
    |> unique_constraint(:hostname)
    |> unique_constraint(:primary, name: :tenant_hostnames_one_primary_index)
    |> foreign_key_constraint(:tenant_id)
  end
end
