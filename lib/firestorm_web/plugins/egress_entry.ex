defmodule FirestormWeb.Plugins.EgressEntry do
  @moduledoc """
  One `http.fetch` a plugin attempted, for its egress log (see
  `FirestormWeb.Plugins.Egress`). `blocked` when nothing was sent; `error`
  is the kind of refusal or failure, `status` the response's.
  """

  use Ecto.Schema

  schema "plugin_egress_entries" do
    field(:plugin_id, :string)
    field(:method, :string)
    field(:host, :string)
    field(:path, :string)
    field(:status, :integer)
    field(:error, :string)
    field(:blocked, :boolean, default: false)
    field(:request_bytes, :integer, default: 0)
    field(:response_bytes, :integer, default: 0)
    field(:duration_ms, :integer, default: 0)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
