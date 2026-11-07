defmodule Firefly.Plugins.InstalledPlugin do
  @moduledoc """
  A plugin's stored state (see `Firefly.Plugins`): whether it's
  enabled, its settings, and for an uploaded plugin the package it came in
  (`package`, which holds the zip and its checksum, see
  `Firefly.Packages`), its parsed `manifest` and its JavaScript joined
  into the one script the sandbox runs (`code`, derived from the zip at
  install so loading needn't rebuild it). A plugin the
  circuit breaker turned off has `disabled_reason`. `fail_closed`: whether
  posting is refused when the plugin's moderation hook fails (see
  `Firefly.Plugins.ModerationHooks`). `secret` authenticates calls to its
  inbound endpoints (see `Firefly.Plugins.UI`).
  """

  use Ecto.Schema

  alias Firefly.Accounts.User

  schema "plugins" do
    field(:plugin_id, :string)
    field(:source, :string)
    field(:version, :string)
    field(:manifest, :map)
    field(:code, :string, redact: true)
    field(:enabled, :boolean, default: false)
    field(:disabled_reason, :string)
    field(:settings, :map, default: %{})
    field(:fail_closed, :boolean, default: false)
    field(:secret, Firefly.Encrypted.Binary, redact: true)
    belongs_to(:installed_by, User)
    belongs_to(:package, Firefly.Packages.Package)

    timestamps(type: :naive_datetime_usec)
  end
end
