defmodule FirestormWeb.Web.ThreadLive.Participating do
  @moduledoc "Threads the current user has posted in."
  use FirestormWeb.Web.ThreadLive.ListView,
    title: "Participating in",
    path: "/threads/participating",
    empty: "You haven't posted in any threads yet."

  defp load(user), do: Forums.participating_threads(user)
end
