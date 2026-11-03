defmodule Firefly.Reports.Report do
  @moduledoc """
  A report (see `Firefly.Reports`): a query module that `use`s this one
  with its `id`, `title` and `description`, and implements `run/1` for a
  date range (`from`..`to`, both inclusive) returning either

    * `{:series, [%{key: key, label: label, points: [{date, value}]}]}`:
      values per day, every day of the range present (`daily/2` fills the
      gaps with zeros), several series for a breakdown; or
    * `{:table, [column label], [row]}`: rows of plain values.

  The helpers query tables by name (not schema), so reports read across
  contexts without reaching into them.
  """

  import Ecto.Query

  @type range :: %{from: Date.t(), to: Date.t()}
  @type result ::
          {:series, [%{key: String.t(), label: String.t(), points: [{Date.t(), number}]}]}
          | {:table, [String.t()], [[term]]}

  @callback id() :: String.t()
  @callback title() :: String.t()
  @callback description() :: String.t()
  @callback run(range) :: result

  defmacro __using__(opts) do
    quote do
      @behaviour Firefly.Reports.Report
      import Firefly.Reports.Report, only: [count_by_day: 3, daily: 2, series: 3, bounds: 1]

      @impl true
      def id, do: unquote(opts[:id])
      @impl true
      def title, do: unquote(opts[:title])
      @impl true
      def description, do: unquote(opts[:description])
    end
  end

  @doc "The range's start and (exclusive) end as naive datetimes, for timestamp columns."
  def bounds(%{from: from, to: to}),
    do:
      {NaiveDateTime.new!(from, ~T[00:00:00]), NaiveDateTime.new!(Date.add(to, 1), ~T[00:00:00])}

  @doc """
  Rows of `query` per day of its timestamp `field` within `range`:
  `[{date, count}]`, only the days that have some.
  """
  def count_by_day(query, field, range) do
    {start, stop} = bounds(range)

    Firefly.Repo.all(
      from(r in query,
        where:
          field(r, ^field) >= type(^start, :naive_datetime) and
            field(r, ^field) < type(^stop, :naive_datetime),
        group_by: fragment("date(?)", field(r, ^field)),
        select: {fragment("date(?)", field(r, ^field)), count()}
      )
    )
  end

  @doc "`counts` (`[{date, value}]`) for every day of `range`, zero where missing."
  def daily(counts, %{from: from, to: to}) do
    counts = Map.new(counts)
    for date <- Date.range(from, to), do: {date, Map.get(counts, date, 0)}
  end

  @doc "A one-series result."
  def series(key, label, points), do: {:series, [%{key: key, label: label, points: points}]}
end
