defmodule Firefly.Packages.Package do
  @moduledoc """
  An installed package (see `Firefly.Packages`): its id, version, tags,
  manifest and the archive it came in (kept to export it and to show what
  an upgrade changes), and where it was fetched from, if it was.
  """

  use Ecto.Schema

  schema "packages" do
    field(:package_id, :string)
    field(:name, :string)
    field(:version, :string)
    field(:tags, {:array, :string}, default: [])
    field(:manifest, :map)
    field(:archive, :binary, redact: true)
    field(:checksum, :string)
    field(:source_url, :string)
    belongs_to(:installed_by, Firefly.Accounts.User)

    timestamps(type: :naive_datetime_usec)
  end
end
