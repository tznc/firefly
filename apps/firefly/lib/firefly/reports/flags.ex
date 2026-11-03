defmodule Firefly.Reports.Flags do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "flags",
    title: "Flags",
    description: "Posts flagged per day."

  @impl true
  def run(range),
    do:
      series(
        "flags",
        "Flags",
        daily(count_by_day("forums_post_flags", :inserted_at, range), range)
      )
end
