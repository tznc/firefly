defmodule FirestormWeb.Web.ThreadLive.Unread do
  @moduledoc "Threads the current user has read before that have new posts."
  use FirestormWeb.Web.ThreadLive.ListView,
    title: nil,
    path: "/unread",
    tabs: true,
    empty: "No unread threads. You're all caught up."

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  defp load(user), do: Forums.unread_threads(user)
end
