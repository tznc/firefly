defmodule FirestormWeb.Plugins.InstalledPlugin do
  @moduledoc """
  A plugin's stored state (see `FirestormWeb.Plugins`): whether it's
  enabled, its settings, and for an uploaded plugin its bundle (the zip and
  its SHA-256 `checksum`), parsed `manifest` and joined `code`. A plugin the
  circuit breaker turned off has `disabled_reason`.
  """

  use Ecto.Schema

  alias FirestormWeb.Forums.User

  schema "plugins" do
    field(:plugin_id, :string)
    field(:source, :string)
    field(:version, :string)
    field(:manifest, :map)
    field(:bundle, :binary, redact: true)
    field(:checksum, :string)
    field(:code, :string, redact: true)
    field(:enabled, :boolean, default: false)
    field(:disabled_reason, :string)
    field(:settings, :map, default: %{})
    belongs_to(:installed_by, User)

    timestamps(type: :naive_datetime_usec)
  end
end
