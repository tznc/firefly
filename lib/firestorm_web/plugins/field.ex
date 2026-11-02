defmodule FirestormWeb.Plugins.Field do
  @moduledoc """
  A plugin's custom field on a post, thread or user (see
  `FirestormWeb.Plugins.Fields`). `value` wraps the JSON value as
  `%{"v" => value}`.
  """
  use Ecto.Schema

  schema "plugin_fields" do
    field(:plugin_id, :string)
    field(:target_type, :string)
    field(:target_id, :integer)
    field(:key, :string)
    field(:value, :map)

    timestamps(type: :naive_datetime_usec)
  end
end
