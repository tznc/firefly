defmodule FireflyWeb.Admin.PackageAdmin do
  @moduledoc """
  Installed packages in the database admin, to read: their zips and
  settings aren't shown. They're installed, upgraded and uninstalled at
  `/staff/packages`.
  """
  use FireflyWeb.Admin.Logged, as: "package"

  def index(_), do: [package_id: nil, version: nil, tags: nil, updated_at: nil]

  def form_fields(_),
    do: [package_id: nil, name: nil, version: nil, checksum: nil, source_url: nil]

  def search_fields(_), do: [:package_id, :name]
  def default_actions(_), do: []
end
