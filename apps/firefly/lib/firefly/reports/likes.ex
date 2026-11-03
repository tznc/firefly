defmodule Firefly.Reports.Likes do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "likes",
    title: "Likes",
    description: "Likes given per day."

  @impl true
  def run(range),
    do:
      series(
        "likes",
        "Likes",
        daily(count_by_day("forums_post_likes", :inserted_at, range), range)
      )
end
