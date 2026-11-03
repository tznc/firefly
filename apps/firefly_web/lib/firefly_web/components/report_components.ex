defmodule FireflyWeb.ReportComponents do
  @moduledoc """
  The dashboard's and reports' pieces (see `Firefly.Reports`): the period
  picker, stat tiles, and charts drawn as inline SVG on the server (no
  chart library, nothing loaded at runtime). Each bar has a tooltip
  (`<title>`); the data is also shown as a table, so nothing is told by
  color alone.
  """
  use FireflyWeb, :html

  alias Firefly.Reports

  @width 640
  @height 200
  @left 44
  @bottom 22
  @top 8

  @doc """
  The period picker: preset links (`7`/`30`/`90`/`365` days) and a custom
  range form, both to `path` with `period` or `from`/`to`.
  """
  attr :path, :string, required: true
  attr :range, :map, required: true
  attr :params, :map, required: true

  def period_picker(assigns) do
    ~H"""
    <div id="period" class="flex flex-wrap items-end gap-2">
      <div class="join">
        <.link
          :for={days <- Reports.presets()}
          patch={@path <> "?period=#{days}"}
          class={[
            "btn btn-sm join-item",
            @params["from"] == nil && @range == Reports.last(days) && "btn-active"
          ]}
        >
          {period_label(days)}
        </.link>
      </div>
      <form id="custom-range" method="get" action={@path} class="flex items-end gap-1">
        <label class="text-xs">
          From <input type="date" name="from" value={@range.from} class="input input-sm w-36" />
        </label>
        <label class="text-xs">
          To <input type="date" name="to" value={@range.to} class="input input-sm w-36" />
        </label>
        <button class="btn btn-sm">Show</button>
      </form>
    </div>
    """
  end

  defp period_label(365), do: "Year"
  defp period_label(days), do: "#{days} days"

  @doc "A number with the previous period's for comparison (see `Firefly.Reports.overview/1`)."
  attr :metric, :map, required: true

  def stat(assigns) do
    ~H"""
    <div id={"stat-#{@metric.key}"} class="rounded-box border border-base-300 bg-base-100 p-4">
      <div class="text-sm text-base-content/70">{@metric.label}</div>
      <div class="stat-value text-2xl font-semibold">{format(@metric.value, @metric.format)}</div>
      <div :if={@metric.previous != nil} class="text-xs text-base-content/70">
        <span class={change_class(@metric)}>{change(@metric)}</span>
        vs {format(@metric.previous, @metric.format)} before
      </div>
    </div>
    """
  end

  @doc "Formats a value: `:count`, `:percent`, `:hours` or `:bytes` (nil: a dash)."
  def format(nil, _format), do: "–"
  def format(value, :percent), do: "#{value}%"
  def format(value, :hours), do: "#{value} h"
  def format(value, :bytes), do: bytes(value)
  def format(value, _count) when is_integer(value), do: delimit(value)
  def format(value, _count), do: to_string(value)

  defp bytes(n) when n >= 1_073_741_824, do: "#{Float.round(n / 1_073_741_824, 1)} GB"
  defp bytes(n) when n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp bytes(n) when n >= 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp bytes(n), do: "#{n} B"

  defp delimit(n) when n < 0, do: "-" <> delimit(-n)

  defp delimit(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp change(%{value: value, previous: previous})
       when is_number(value) and is_number(previous) do
    cond do
      previous == 0 and value == 0 ->
        "no change"

      previous == 0 ->
        "new"

      true ->
        "#{if value >= previous, do: "+", else: ""}#{round((value - previous) * 100 / previous)}%"
    end
  end

  defp change(_metric), do: ""

  # Time to first response is better when lower.
  defp change_class(%{value: v, previous: p, key: key}) when is_number(v) and is_number(p) do
    better = if key == "first_response", do: v < p, else: v > p

    cond do
      v == p -> nil
      better -> "text-success"
      true -> "text-error"
    end
  end

  defp change_class(_metric), do: nil

  @doc """
  A report's result: a bar chart (stacked for several series) with a
  legend and a table of the values, or just the table.
  """
  attr :id, :string, required: true
  attr :result, :any, required: true
  attr :table, :boolean, default: true, doc: "show the values as a table under the chart"

  def report_result(%{result: {:series, _}} = assigns) do
    ~H"""
    <div id={@id} class="space-y-3">
      <.bar_chart series={elem(@result, 1)} />
      <.series_table :if={@table} series={elem(@result, 1)} />
    </div>
    """
  end

  def report_result(%{result: {:table, _, _}} = assigns) do
    ~H"""
    <div id={@id} class="overflow-x-auto">
      <p :if={elem(@result, 2) == []} class="text-base-content/70">No data for this period.</p>
      <table :if={elem(@result, 2) != []} class="table table-sm">
        <thead>
          <tr><th :for={column <- elem(@result, 1)}>{column}</th></tr>
        </thead>
        <tbody>
          <tr :for={row <- elem(@result, 2)}>
            <td :for={value <- row}>{format(value, :count)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :series, :list, required: true

  defp series_table(assigns) do
    ~H"""
    <details class="text-sm">
      <summary class="cursor-pointer text-base-content/70">Show the values</summary>
      <div class="max-h-80 overflow-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th>Date</th>
              <th :for={s <- @series}>{s.label}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{date, i} <- Enum.with_index(dates(@series))}>
              <td>{date}</td>
              <td :for={s <- @series}>{format(elem(Enum.at(s.points, i), 1), :count)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end

  defp dates([%{points: points} | _]), do: Enum.map(points, &elem(&1, 0))

  @doc "Bars per day, stacked by series, with a legend when there are several."
  attr :series, :list, required: true

  def bar_chart(assigns) do
    assigns = assign(assigns, :chart, layout(assigns.series))

    ~H"""
    <figure class="chart space-y-2">
      <ul :if={length(@series) > 1} class="flex flex-wrap gap-3 text-xs">
        <li :for={{s, i} <- Enum.with_index(@series, 1)} class="flex items-center gap-1">
          <span class={["inline-block size-3 rounded-sm", "series-#{i}"]}></span>{s.label}
        </li>
      </ul>
      <svg
        viewBox={"0 0 #{@chart.width} #{@chart.height}"}
        class="h-auto w-full text-base-content"
        role="img"
        aria-label={chart_label(@series)}
      >
        <g :for={tick <- @chart.ticks} class="text-base-content/40">
          <line x1={@chart.left} x2={@chart.width} y1={tick.y} y2={tick.y} stroke="currentColor" stroke-width="0.5" />
          <text x={@chart.left - 6} y={tick.y + 3} text-anchor="end" font-size="10" fill="currentColor" class="text-base-content/70">
            {format(tick.value, :count)}
          </text>
        </g>
        <g :for={bar <- @chart.bars}>
          <title>{bar.title}</title>
          <rect
            :for={seg <- bar.segments}
            class={["bar", "series-#{seg.series}"]}
            x={bar.x}
            y={seg.y}
            width={bar.width}
            height={seg.height}
            rx={if seg.top, do: min(4, bar.width / 2), else: 0}
          />
          <rect x={bar.x} y={@chart.top} width={bar.width} height={@chart.plot_height} fill="transparent" />
        </g>
        <text
          :for={label <- @chart.labels}
          x={label.x}
          y={@chart.height - 6}
          text-anchor="middle"
          font-size="10"
          fill="currentColor"
          class="text-base-content/70"
        >
          {label.text}
        </text>
      </svg>
    </figure>
    """
  end

  defp chart_label(series),
    do: Enum.map_join(series, ", ", fn s -> "#{s.label} per day" end)

  # Bars, segments, gridlines and date labels in viewBox units.
  defp layout(series) do
    days = series |> dates() |> length() |> max(1)
    plot_width = @width - @left
    plot_height = @height - @top - @bottom
    slot = plot_width / days
    gap = if slot > 6, do: 2, else: 0
    totals = for i <- 0..(days - 1), do: Enum.sum(for s <- series, do: value(s, i))
    max = nice_max(Enum.max(totals, fn -> 0 end))
    scale = plot_height / max

    bars =
      for {date, i} <- Enum.with_index(dates(series)) do
        x = @left + i * slot + gap / 2

        {segments, _} =
          series
          |> Enum.with_index(1)
          |> Enum.map_reduce(@top + plot_height, fn {s, n}, base ->
            h = value(s, i) * scale
            {%{series: n, y: base - h, height: h, top: false}, base - h}
          end)

        segments = Enum.reject(segments, &(&1.height <= 0))
        segments = List.update_at(segments, -1, &%{&1 | top: true})

        %{
          x: x,
          width: max(slot - gap, 0.5),
          segments: segments,
          title:
            Enum.join(
              [Date.to_iso8601(date) | for(s <- series, do: "#{s.label}: #{value(s, i)}")],
              "\n"
            )
        }
      end

    %{
      width: @width,
      height: @height,
      left: @left,
      top: @top,
      plot_height: plot_height,
      bars: bars,
      ticks:
        for(
          step <- 0..2,
          do: %{value: div(max * step, 2), y: @top + plot_height - plot_height * step / 2}
        ),
      labels: date_labels(dates(series), slot)
    }
  end

  defp value(%{points: points}, i), do: elem(Enum.at(points, i), 1) || 0

  # A round maximum for the axis, at least 2 so the halfway line is whole.
  defp nice_max(max) when max <= 2, do: 2

  defp nice_max(max) do
    magnitude = Integer.pow(10, max |> ceil() |> Integer.digits() |> length() |> Kernel.-(1))
    step = Enum.find([1, 2, 5, 10], &(&1 * magnitude >= max / 1))
    if rem(step * magnitude, 2) == 0, do: step * magnitude, else: step * magnitude + 1
  end

  # First, middle and last day.
  defp date_labels(dates, slot) do
    count = length(dates)

    for i <- Enum.uniq([0, div(count - 1, 2), count - 1]), i >= 0 do
      %{
        x: @left + i * slot + slot / 2,
        text: Calendar.strftime(Enum.at(dates, i), "%b %-d")
      }
    end
  end
end
