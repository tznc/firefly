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
    |> subscribe_to_notifications()
    |> attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
      {:cont, assign(socket, :current_path, URI.parse(uri).path)}
    end)
  end

  defp notification_count(nil), do: 0
  defp notification_count(user), do: Forums.unread_notification_count(user)

  # Keeps the notification badge live: notify/read broadcasts
  # :notifications_changed on the user's topic. Views can export
  # `notifications_changed/1` to react as well (e.g. the notifications page).
  defp subscribe_to_notifications(%{assigns: %{current_user: %{id: user_id}}} = socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(FirestormWeb.PubSub, Forums.notifications_topic(user_id))

      attach_hook(socket, :notifications, :handle_info, &handle_notifications/2)
    else
      socket
    end
  end

  defp subscribe_to_notifications(socket), do: socket

  defp handle_notifications(:notifications_changed, socket) do
    socket = assign(socket, :notification_count, notification_count(socket.assigns.current_user))

    socket =
      if function_exported?(socket.view, :notifications_changed, 1),
        do: socket.view.notifications_changed(socket),
        else: socket

    {:halt, socket}
  end

  defp handle_notifications(_other, socket), do: {:cont, socket}
end
