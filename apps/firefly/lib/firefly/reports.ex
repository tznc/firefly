defmodule Firefly.Reports do
  @moduledoc """
  The Reports context: the admin dashboard's overview (`overview/1`) and
  reports (`list/0`), as in Discourse. Each report is a query module (see
  `Firefly.Reports.Report`) returning a daily series or a table for a date
  range; `to_csv/1` exports one.

  Aggregates can be expensive, so results are cached per day
  (`Firefly.Reports.Cache`): the same report for the same range is
  computed once a day per node, unless asked to refresh. Ranges are whole
  days in UTC, `from` and `to` included; `previous/1` is the period just
  before one, of the same length, for comparison.
  """

  use Boundary, top_level?: true, check: [out: false], exports: []

  import Ecto.Query, except: [last: 1, last: 2]

  alias Firefly.{Analytics, Repo}
  alias Firefly.Moderation.Review
  alias Firefly.Reports.{Cache, Report}

  @reports [
    Firefly.Reports.Signups,
    Firefly.Reports.Topics,
    Firefly.Reports.Posts,
    Firefly.Reports.Likes,
    Firefly.Reports.Flags,
    Firefly.Reports.Messages,
    Firefly.Reports.ChatMessages,
    Firefly.Reports.PageViews,
    Firefly.Reports.TopReferrers,
    Firefly.Reports.TopTrafficTopics,
    Firefly.Reports.UserVisits,
    Firefly.Reports.TimeToFirstResponse,
    Firefly.Reports.TopicsWithoutResponse,
    Firefly.Reports.TopPosters,
    Firefly.Reports.Uploads,
    Firefly.Reports.TopUploaders,
    Firefly.Reports.TrustLevels,
    Firefly.Reports.Emails,
    Firefly.Reports.WebhookFailures,
    Firefly.Reports.Penalties,
    Firefly.Reports.StaffActions
  ]

  @presets [7, 30, 90, 365]

  @doc "Every report module, in display order."
  def list, do: @reports

  @doc "The report module with `id`, or nil."
  def get(id), do: Enum.find(@reports, &(&1.id() == id))

  ## Ranges

  @doc "The preset periods, in days."
  def presets, do: @presets

  @doc "The last `days` days, today included."
  def last(days, today \\ Date.utc_today()), do: %{from: Date.add(today, 1 - days), to: today}

  @doc """
  The range `params` ask for: `"period"` (a preset's days), or `"from"` and
  `"to"` (ISO dates, at most two years apart); the last 30 days otherwise.
  """
  def range(params) do
    with {:ok, from} <- Date.from_iso8601(params["from"] || ""),
         {:ok, to} <- Date.from_iso8601(params["to"] || ""),
         true <- Date.compare(from, to) != :gt and Date.diff(to, from) <= 731 do
      %{from: from, to: to}
    else
      _ ->
        case Integer.parse(params["period"] || "") do
          {days, ""} when days in @presets -> last(days)
          _ -> last(30)
        end
    end
  end

  @doc "The period of the same length just before `range`."
  def previous(%{from: from, to: to}) do
    days = Date.diff(to, from) + 1
    %{from: Date.add(from, -days), to: Date.add(from, -1)}
  end

  ## Running

  @doc """
  Runs `report` for `range`: `%{result: result, computed_at: datetime}`
  (`result` as `Firefly.Reports.Report`'s `run/1`). Cached for the day
  unless `refresh: true`.
  """
  def run(report, range, opts \\ []) do
    cached({:report, report.id(), range}, opts, fn -> report.run(range) end)
  end

  defp cached(key, opts, fun) do
    if opts[:refresh], do: Cache.delete(key)
    Cache.fetch(key, fun)
  end

  @doc "A series result's total per series: `[{label, total}]`."
  def totals({:series, series}),
    do: for(s <- series, do: {s.label, Enum.reduce(s.points, 0, fn {_, v}, acc -> acc + v end)})

  @doc "A result as CSV (a header row, then the data)."
  def to_csv({:series, series}) do
    header = ["Date" | Enum.map(series, & &1.label)]
    dates = series |> hd() |> Map.fetch!(:points) |> Enum.map(&elem(&1, 0))
    by_date = Enum.map(series, &Map.new(&1.points))
    rows = for date <- dates, do: [Date.to_iso8601(date) | Enum.map(by_date, & &1[date])]
    csv([header | rows])
  end

  def to_csv({:table, columns, rows}), do: csv([columns | rows])

  defp csv(rows),
    do: Enum.map_join(rows, &(Enum.map_join(&1, ",", fn v -> cell(v) end) <> "\r\n"))

  defp cell(nil), do: ""
  defp cell(value) when is_number(value), do: to_string(value)

  defp cell(value) do
    text = to_string(value)
    # Spreadsheets run cells starting with these as formulas.
    text = if String.starts_with?(text, ~w(= + - @)), do: "'" <> text, else: text

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(text, "\"", "\"\"") <> "\"",
      else: text
  end

  ## Overview

  @doc """
  The dashboard's numbers for `range`, each with the previous period's
  value for comparison (`previous: nil` for those that are only "now"):
  `%{metrics: [%{key, label, value, previous, format}], computed_at}`.
  `format` is `:count`, `:percent`, `:hours` or `:bytes`.
  """
  def overview(range, opts \\ []) do
    cached({:overview, range}, opts, fn ->
      before = previous(range)

      compared =
        for {key, label, format, fun} <- compared_metrics() do
          %{key: key, label: label, format: format, value: fun.(range), previous: fun.(before)}
        end

      compared ++
        [
          %{
            key: "review_queue",
            label: "Waiting for review",
            format: :count,
            value: Review.pending_count(),
            previous: nil
          },
          %{
            key: "storage",
            label: "Upload storage",
            format: :bytes,
            value: upload_bytes(),
            previous: nil
          }
        ]
    end)
  end

  defp compared_metrics do
    [
      {"signups", "Signups", :count, &total(Firefly.Reports.Signups, &1)},
      {"topics", "Topics", :count, &total(Firefly.Reports.Topics, &1)},
      {"posts", "Posts", :count, &total(Firefly.Reports.Posts, &1)},
      {"likes", "Likes", :count, &total(Firefly.Reports.Likes, &1)},
      {"flags", "Flags", :count, &total(Firefly.Reports.Flags, &1)},
      {"page_views", "Page views", :count, &page_views/1},
      {"dau", "Daily active users", :count, &daily_active/1},
      {"mau", "Monthly active users", :count, &monthly_active/1},
      {"response_rate", "Topics with a response", :percent, &response_rate/1},
      {"first_response", "Time to first response", :hours, &first_response/1}
    ]
  end

  defp total(report, range) do
    {:series, [%{points: points}]} = report.run(range)
    Enum.reduce(points, 0, fn {_, n}, acc -> acc + n end)
  end

  defp page_views(range) do
    range.from
    |> Analytics.page_views(range.to)
    |> Enum.reduce(0, fn {_, _, n}, acc -> acc + n end)
  end

  # Average members a day.
  defp daily_active(range) do
    visits =
      Repo.one(
        from(v in "user_visits",
          where: v.visited_on >= ^range.from and v.visited_on <= ^range.to,
          select: count()
        )
      )

    round(visits / (Date.diff(range.to, range.from) + 1))
  end

  # Members who came in the 30 days to the end of the period.
  defp monthly_active(range) do
    from = Date.add(range.to, -29)

    Repo.one(
      from(v in "user_visits",
        where: v.visited_on >= ^from and v.visited_on <= ^range.to,
        select: count(v.user_id, :distinct)
      )
    )
  end

  defp response_rate(range) do
    {start, stop} = Report.bounds(range)

    %{rows: [[total, answered]]} =
      Repo.query!(
        """
        SELECT count(*), count(*) FILTER (WHERE EXISTS (
          SELECT 1 FROM forums_posts p
          WHERE p.thread_id = t.id AND p.deleted_at IS NULL
            AND p.user_id <> (SELECT f.user_id FROM forums_posts f WHERE f.thread_id = t.id
                              ORDER BY f.inserted_at, f.id LIMIT 1)))
        FROM forums_threads t
        WHERE t.inserted_at >= $1 AND t.inserted_at < $2 AND t.merged_into_id IS NULL
        """,
        [start, stop]
      )

    if total == 0, do: nil, else: round(answered * 100 / total)
  end

  # The median, in hours.
  defp first_response(range) do
    {start, stop} = Report.bounds(range)

    %{rows: [[hours]]} =
      Repo.query!(
        """
        SELECT round((percentile_cont(0.5) WITHIN GROUP (
          ORDER BY extract(epoch FROM r.at - t.inserted_at)) / 3600)::numeric, 1)::float
        FROM forums_threads t
        JOIN LATERAL (
          SELECT min(p.inserted_at) AS at FROM forums_posts p
          WHERE p.thread_id = t.id AND p.deleted_at IS NULL
            AND p.user_id <> (SELECT f.user_id FROM forums_posts f WHERE f.thread_id = t.id
                              ORDER BY f.inserted_at, f.id LIMIT 1)
        ) r ON r.at IS NOT NULL
        WHERE t.inserted_at >= $1 AND t.inserted_at < $2
        """,
        [start, stop]
      )

    hours
  end

  defp upload_bytes,
    do: Repo.one(from(u in "uploads", select: type(coalesce(sum(u.size), 0), :integer)))
end
