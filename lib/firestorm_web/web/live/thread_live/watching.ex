defmodule FirestormWeb.Web.ThreadLive.Watching do
  @moduledoc "Threads the current user is watching."
  use FirestormWeb.Web.ThreadLive.ListView,
    title: "Watching",
    path: "/threads/watching",
    empty: "You're not watching any threads yet."

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  defp load(user), do: Forums.watched_threads(user)
end
