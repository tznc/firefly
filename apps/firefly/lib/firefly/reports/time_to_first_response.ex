defmodule Firefly.Reports.TimeToFirstResponse do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "time_to_first_response",
    title: "Time to first response",
    description:
      "Average hours until someone other than the author replied, by the day topics were started (topics still without a reply aren't counted)."

  @impl true
  def run(range) do
    {start, stop} = bounds(range)

    %{rows: rows} =
      Firefly.Repo.query!(
        """
        SELECT date(t.inserted_at), round(avg(extract(epoch FROM r.at - t.inserted_at)) / 3600, 1)::float
        FROM forums_threads t
        JOIN LATERAL (
          SELECT min(p.inserted_at) AS at FROM forums_posts p
          WHERE p.thread_id = t.id AND p.deleted_at IS NULL
            AND p.user_id <> (SELECT f.user_id FROM forums_posts f WHERE f.thread_id = t.id
                              ORDER BY f.inserted_at, f.id LIMIT 1)
        ) r ON r.at IS NOT NULL
        WHERE t.inserted_at >= $1 AND t.inserted_at < $2
        GROUP BY 1
        """,
        [start, stop]
      )

    series("hours", "Hours", daily(Enum.map(rows, &List.to_tuple/1), range))
  end
end
