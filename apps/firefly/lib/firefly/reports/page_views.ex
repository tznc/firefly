defmodule Firefly.Reports.PageViews do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "page_views",
    title: "Page views",
    description: "Page views per day by kind: logged in, anonymous, crawlers and API requests."

  alias Firefly.Analytics

  @impl true
  def run(range) do
    rows = Analytics.page_views(range.from, range.to)

    {:series,
     for kind <- Analytics.kinds() do
       counts = for {date, ^kind, count} <- rows, do: {date, count}
       %{key: kind, label: Analytics.label(kind), points: daily(counts, range)}
     end}
  end
end
