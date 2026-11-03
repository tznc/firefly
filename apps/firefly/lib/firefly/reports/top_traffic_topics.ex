defmodule Firefly.Reports.TopTrafficTopics do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "top_traffic_topics",
    title: "Top traffic topics",
    description: "The topics viewed most (each viewer counted once a day)."

  @impl true
  def run(range) do
    {:table, ["Topic", "Views"],
     for(
       {thread, views} <- Firefly.Analytics.top_topics(range.from, range.to, 50),
       do: [thread.title, views]
     )}
  end
end
