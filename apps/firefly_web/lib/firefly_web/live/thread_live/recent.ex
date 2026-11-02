defmodule FireflyWeb.ThreadLive.Recent do
  @moduledoc "The home page (Latest): the most recently active threads across all categories."
  use FireflyWeb.ThreadLive.ListView,
    title: nil,
    path: "/",
    tabs: true,
    intro: true,
    empty: "No threads yet."

  defp load(user), do: Discussion.latest_threads(user)
end
