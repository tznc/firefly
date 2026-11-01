defmodule FirestormWeb.Web.ThreadLive.NewThreads do
  @moduledoc "Recently started threads the current user hasn't opened yet."
  use FirestormWeb.Web.ThreadLive.ListView,
    title: nil,
    path: "/new",
    tabs: true,
    empty: "No new threads. You're all caught up."

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  defp load(user), do: Forums.new_threads(user)
end
