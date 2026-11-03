defmodule Firefly.Webhooks.Delivery do
  @moduledoc """
  One event for one webhook (see `Firefly.Webhooks`): queued (`pending`,
  due at `run_at`), then `delivered`, `failed` (out of attempts) or
  `skipped` (the webhook was off or gone). The last attempt's request and
  response are kept, bodies truncated, for the delivery log.
  """
  use Ecto.Schema

  alias Firefly.Webhooks.Webhook

  schema "webhook_deliveries" do
    field(:event_id, Ecto.UUID)
    field(:event, :string)
    field(:payload, :map)
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:run_at, :utc_datetime_usec)
    field(:request_headers, :map)
    field(:request_body, :string)
    field(:response_status, :integer)
    field(:response_headers, :map)
    field(:response_body, :string)
    field(:error, :string)
    field(:duration_ms, :integer)
    field(:delivered_at, :utc_datetime)
    belongs_to(:webhook, Webhook)

    timestamps(type: :naive_datetime_usec)
  end
end
