defmodule FireflyWeb.Admin.PluginAdmin do
  @moduledoc """
  Installed plugins in the database admin, to read: their code, secrets
  and settings (which can hold API keys) aren't shown; an uploaded
  plugin's zip is its package's (see `FireflyWeb.Admin.PackageAdmin`).
  They're installed, configured and switched on or off at
  `/staff/packages`.
  """
  use FireflyWeb.Admin.Logged, as: "plugin"

  def index(_), do: [plugin_id: nil, version: nil, enabled: nil, source: nil, updated_at: nil]

  def form_fields(_),
    do: [
      plugin_id: nil,
      version: nil,
      source: nil,
      enabled: nil,
      disabled_reason: nil,
      package_id: nil
    ]

  def search_fields(_), do: [:plugin_id]
  def default_actions(_), do: []
end
