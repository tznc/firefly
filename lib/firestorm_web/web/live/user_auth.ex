defmodule FirestormWeb.Web.UserAuth do
  @moduledoc """
  `on_mount` hooks for LiveViews:

    * `:mount_current_user` - assigns `:current_user` (or nil) from the session,
      the unread notification count and the current path.
    * `:require_user` - redirects to the categories page when nobody is
      logged in. Used by individual LiveViews, after the live session's
      `:mount_current_user`.
  """

  use FirestormWeb.Web, :verified_routes

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView

  alias FirestormWeb.Forums
  alias FirestormWeb.Web.Session

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:require_user, params, session, socket) do
    {:cont, socket} =
      if Map.has_key?(socket.assigns, :current_user),
        do: {:cont, socket},
        else: on_mount(:mount_current_user, params, session, socket)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You must be logged in to access this page.")
        |> redirect(to: ~p"/categories")

      {:halt, socket}
    end
  end

  defp mount_current_user(socket, session) do
    socket
    |> assign_new(:current_user, fn -> Session.user_from_id(session["current_user"]) end)
    |> then(&assign(&1, :notification_count, notification_count(&1.assigns.current_user)))
    |> attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
      {:cont, assign(socket, :current_path, URI.parse(uri).path)}
    end)
  end

  defp notification_count(nil), do: 0
  defp notification_count(user), do: user |> Forums.notifications_for() |> length()
end
