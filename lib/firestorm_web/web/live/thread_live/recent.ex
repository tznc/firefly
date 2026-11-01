defmodule FirestormWeb.Web.ThreadLive.Recent do
  @moduledoc "The home page (Latest): the most recently active threads across all categories."
  use FirestormWeb.Web.ThreadLive.ListView,
    title: nil,
    path: "/",
    tabs: true,
    intro: true,
    empty: "No threads yet."

  defp load(user), do: Forums.latest_threads(user)
end
