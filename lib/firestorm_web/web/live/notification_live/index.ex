defmodule FirestormWeb.Web.NotificationLive.Index do
  @moduledoc "The current user's notifications, newest first; updates live."
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.Notification

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Notifications") |> load()}
  end

  @doc false
  def notifications_changed(socket), do: load(socket)

  defp load(socket),
    do: assign(socket, :notifications, Forums.notifications_for(socket.assigns.current_user))

  @impl true
  def handle_event("open", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.notifications, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      notification ->
        {:ok, notification} = Forums.mark_notification_read(notification)
        {:noreply, push_navigate(socket, to: Notification.path(notification))}
    end
  end

  def handle_event("read_all", _params, socket) do
    Forums.mark_all_notifications_read(socket.assigns.current_user)
    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Notifications">
        <:actions>
          <button
            :if={Enum.any?(@notifications, &(!Notification.read?(&1)))}
            id="read-all"
            phx-click="read_all"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-check" class="size-4" /> Mark all as read
          </button>
          <.link navigate={~p"/settings/notifications"} class="btn btn-ghost btn-sm">
            <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
          </.link>
        </:actions>
      </.page_header>

      <ol id="notifications" class="list rounded-box border border-base-300 bg-base-100">
        <li :if={@notifications == []} class="list-row text-base-content/60">
          You have no notifications.
        </li>
        <li
          :for={notification <- @notifications}
          id={"notification-#{notification.id}"}
          class={["list-row", !Notification.read?(notification) && "unread bg-primary/5"]}
        >
          <.icon
            name={if notification.kind == "new_thread", do: "hero-chat-bubble-left", else: "hero-arrow-uturn-left"}
            class={["size-5", if(Notification.read?(notification), do: "opacity-50", else: "text-primary")]}
          />
          <button
            type="button"
            phx-click="open"
            phx-value-id={notification.id}
            class={[
              "list-col-grow text-left hover:text-primary",
              !Notification.read?(notification) && "font-semibold"
            ]}
          >
            {notification.subject}
            <span class="block line-clamp-1 text-sm font-normal text-base-content/60">
              {notification.body}
            </span>
          </button>
          <.time_ago id={"notification-#{notification.id}-time"} at={notification.inserted_at} />
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
