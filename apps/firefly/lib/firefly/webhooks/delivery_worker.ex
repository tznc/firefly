defmodule Firefly.Webhooks.DeliveryWorker do
  @moduledoc """
  Sends one webhook delivery (see `Firefly.Webhooks.deliver/2`), as an Oban
  job in the `webhooks` queue: up to 5 attempts, retried after 30 seconds,
  2 minutes, 8 minutes and 32 minutes. The delivery's row is the log staff
  see, attempt by attempt.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 5

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 30 * 4 ** (attempt - 1)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}}), do: Firefly.Webhooks.deliver(id)
end
