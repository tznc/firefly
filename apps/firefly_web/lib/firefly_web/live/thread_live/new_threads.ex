defmodule FireflyWeb.ThreadLive.NewThreads do
  @moduledoc "Recently started threads the current user hasn't opened yet."
  use FireflyWeb.ThreadLive.ListView,
    title: nil,
    path: "/new",
    tabs: true,
    empty: "No new threads. You're all caught up."

  on_mount({FireflyWeb.UserAuth, :require_user})

  defp load(user), do: Discussion.new_threads(user)
end
