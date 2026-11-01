defmodule FirestormWeb.Web.ThreadLive.Recent do
  @moduledoc "The home page: the most recently active threads across all categories."
  use FirestormWeb.Web.ThreadLive.ListView, title: nil, path: nil, empty: "No threads yet."

  defp load(user), do: Forums.home_threads(user)
end
