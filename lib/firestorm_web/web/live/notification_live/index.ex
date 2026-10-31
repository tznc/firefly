defmodule FirestormWeb.Web.NotificationLive.Index do
  @moduledoc "The current user's notifications."
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Forums

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Notifications")
     |> assign(:notifications, Forums.notifications_for(socket.assigns.current_user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Notifications" />

      <ol id="notifications" class="list rounded-box border border-base-300 bg-base-100">
        <li :if={@notifications == []} class="list-row text-base-content/60">
          You have no notifications.
        </li>
        <li :for={notification <- @notifications} id={"notification-#{notification.id}"} class="list-row">
          <.icon name="hero-bell" class="size-5 text-primary" />
          <.link navigate={~p"/notifications/#{notification}"} class="list-col-grow hover:text-primary">
            {notification.subject}
          </.link>
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
