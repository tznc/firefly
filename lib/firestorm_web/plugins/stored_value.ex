defmodule FirestormWeb.Plugins.StoredValue do
  @moduledoc """
  One key of a plugin's key-value storage (see `FirestormWeb.Plugins.Storage`):
  plugin-global when `user_id` is nil, else that member's.
  `value` wraps the JSON value as `%{"v" => value}`; `size` is its encoded size.
  """
  use Ecto.Schema

  schema "plugin_kv" do
    field(:plugin_id, :string)
    field(:user_id, :integer)
    field(:key, :string)
    field(:value, :map)
    field(:size, :integer)

    timestamps(type: :naive_datetime_usec)
  end
end
