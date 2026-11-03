defmodule Firefly.Reports.Sentiment do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "sentiment",
    title: "Sentiment",
    description: "Posts AI triage rated positive, neutral or negative, per day."

  import Ecto.Query

  @impl true
  def run(range) do
    {start, stop} = bounds(range)

    rows =
      Firefly.Repo.all(
        from(c in "ai_post_classifications",
          where:
            c.inserted_at >= type(^start, :naive_datetime) and
              c.inserted_at < type(^stop, :naive_datetime),
          group_by: [fragment("date(?)", c.inserted_at), c.sentiment],
          select: {fragment("date(?)", c.inserted_at), c.sentiment, count()}
        )
      )

    {:series,
     for sentiment <- ~w(positive neutral negative) do
       points = for {date, ^sentiment, n} <- rows, do: {date, n}
       %{key: sentiment, label: String.capitalize(sentiment), points: daily(points, range)}
     end}
  end
end
