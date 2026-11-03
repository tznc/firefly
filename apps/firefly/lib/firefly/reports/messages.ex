defmodule Firefly.Reports.Messages do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "messages",
    title: "Private messages",
    description: "Private messages sent per day."

  @impl true
  def run(range),
    do:
      series(
        "messages",
        "Private messages",
        daily(count_by_day("forums_messages", :inserted_at, range), range)
      )
end
