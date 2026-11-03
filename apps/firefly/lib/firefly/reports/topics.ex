defmodule Firefly.Reports.Topics do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "topics",
    title: "Topics",
    description: "New topics (threads) per day."

  @impl true
  def run(range),
    do:
      series(
        "topics",
        "Topics",
        daily(count_by_day("forums_threads", :inserted_at, range), range)
      )
end
