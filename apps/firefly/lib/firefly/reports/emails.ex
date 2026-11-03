defmodule Firefly.Reports.Emails do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "emails",
    title: "Notification emails",
    description:
      "Notifications sent by email per day (digests and mailing list emails aren't logged)."

  @impl true
  def run(range),
    do:
      series(
        "emails",
        "Notification emails",
        daily(count_by_day("forums_notifications", :emailed_at, range), range)
      )
end
