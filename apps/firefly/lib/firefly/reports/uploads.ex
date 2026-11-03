defmodule Firefly.Reports.Uploads do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "uploads",
    title: "Uploads",
    description: "Files uploaded per day."

  @impl true
  def run(range),
    do: series("uploads", "Uploads", daily(count_by_day("uploads", :inserted_at, range), range))
end
