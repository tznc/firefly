defmodule FireflyWeb.ThreadLive.Unread do
  @moduledoc "Threads the current user has read before that have new posts."
  use FireflyWeb.ThreadLive.ListView,
    title: nil,
    path: "/unread",
    tabs: true,
    empty: "No unread threads. You're all caught up."

  on_mount({FireflyWeb.UserAuth, :require_user})

  defp load(user), do: Forums.unread_threads(user)
end
