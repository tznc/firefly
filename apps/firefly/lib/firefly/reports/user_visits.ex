defmodule Firefly.Reports.UserVisits do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "user_visits",
    title: "Daily active users",
    description: "Members who visited each day (logged in)."

  import Ecto.Query

  @impl true
  def run(range) do
    counts =
      Firefly.Repo.all(
        from(v in "user_visits",
          where: v.visited_on >= ^range.from and v.visited_on <= ^range.to,
          group_by: v.visited_on,
          select: {v.visited_on, count()}
        )
      )

    series("user_visits", "Members", daily(counts, range))
  end
end
