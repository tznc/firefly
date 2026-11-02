defmodule FireflyWeb.ThreadLive.Participating do
  @moduledoc "Threads the current user has posted in."
  use FireflyWeb.ThreadLive.ListView,
    title: "Participating in",
    path: "/threads/participating",
    empty: "You haven't posted in any threads yet."

  on_mount({FireflyWeb.UserAuth, :require_user})

  defp load(user), do: Discussion.participating_threads(user)
end
