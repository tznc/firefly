defmodule Firefly.Reports.TopReferrers do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "top_referrers",
    title: "Top referrers",
    description: "The sites that sent the most visitors."

  @impl true
  def run(range) do
    {:table, ["Domain", "Visits"],
     for(
       {domain, count} <- Firefly.Analytics.top_referrers(range.from, range.to, 50),
       do: [domain, count]
     )}
  end
end
