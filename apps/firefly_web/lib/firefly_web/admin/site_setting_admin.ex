defmodule FireflyWeb.Admin.SiteSettingAdmin do
  @moduledoc """
  The stored site settings in the database admin, to read: they're
  changed at `/staff/settings`, which checks values and reloads every
  node. Secret settings (API keys) aren't listed.
  """
  use FireflyWeb.Admin.Logged, as: "site_setting"

  import Ecto.Query

  def index(_), do: [key: nil, value: nil, updated_at: nil]
  def form_fields(_), do: [key: nil, value: nil]
  def search_fields(_), do: [:key]
  def default_actions(_), do: []

  def custom_index_query(_conn, _schema, query), do: without_secrets(query)
  def custom_show_query(_conn, _schema, query), do: without_secrets(query)

  defp without_secrets(query) do
    secrets = for %{secret: true, key: key} <- Firefly.SiteSettings.definitions(), do: key
    where(query, [s], s.key not in ^secrets)
  end
end
