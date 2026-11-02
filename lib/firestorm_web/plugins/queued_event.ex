defmodule FirestormWeb.Plugins.QueuedEvent do
  @moduledoc """
  An event waiting to be delivered to a plugin (see
  `FirestormWeb.Plugins.Events`), with its failed attempts so far.
  """
  use Ecto.Schema

  schema "plugin_queue" do
    field(:plugin_id, :string)
    field(:event, :string)
    field(:payload, :map, default: %{})
    field(:attempts, :integer, default: 0)
    field(:run_at, :utc_datetime_usec)
    field(:last_error, :string)

    timestamps(type: :naive_datetime_usec)
  end
end
