defmodule Firefly.Reports.WebhookFailures do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "webhook_failures",
    title: "Webhook failures",
    description: "Webhook deliveries given up on after every retry failed, per day."

  import Ecto.Query

  @impl true
  def run(range),
    do:
      series(
        "webhook_failures",
        "Webhook failures",
        daily(
          count_by_day(
            from(r in "webhook_deliveries", where: r.status == "failed"),
            :updated_at,
            range
          ),
          range
        )
      )
end
