defmodule Firefly.Packages.Package do
  @moduledoc """
  An installed package (see `Firefly.Packages`): its id, version, tags,
  manifest and the archive it came in (kept to export it and to show what
  an upgrade changes), and where it was fetched from, if it was. A theme
  package's setting values (only those changed from their defaults), and
  for a plugin's package with theme components, when staff granted it
  that and who.
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
    field(:settings, :map, default: %{})
    field(:theme_granted_at, :utc_datetime)
    belongs_to(:theme_granted_by, Firefly.Accounts.User)
    belongs_to(:installed_by, Firefly.Accounts.User)

    timestamps(type: :naive_datetime_usec)
  end
end
