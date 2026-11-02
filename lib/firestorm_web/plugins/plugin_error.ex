defmodule FirestormWeb.Plugins.PluginError do
  @moduledoc """
  One failure of a plugin, for its error log at `/staff/plugins/:id`: the
  hook (or host function) and the kind of failure (see
  `FirestormWeb.Plugin.Runner`).
  """

  use Ecto.Schema

  schema "plugin_errors" do
    field(:plugin_id, :string)
    field(:hook, :string)
    field(:kind, :string)
    field(:message, :string)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
