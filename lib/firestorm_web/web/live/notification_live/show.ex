defmodule FirestormWeb.Web.NotificationLive.Show do
  @moduledoc "One of the current user's notifications."
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.Forums

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Forums.get_notification(id) do
      %{user_id: user_id} = notification when user_id == user.id ->
        {:ok,
         socket
         |> assign(:page_title, notification.subject)
         |> assign(:notification, notification)}

      _missing_or_someone_elses ->
        {:ok,
         socket
         |> put_flash(:error, "Notification not found.")
         |> push_navigate(to: ~p"/notifications")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title={@notification.subject} />

      <div class="card border border-base-300 bg-base-100">
        <div class="card-body">
          <p class="whitespace-pre-line">{@notification.body}</p>
          <div class="card-actions justify-end">
            <a href={@notification.url} class="btn btn-primary">Visit</a>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
