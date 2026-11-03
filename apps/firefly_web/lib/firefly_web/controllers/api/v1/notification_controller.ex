defmodule FireflyWeb.Api.V1.NotificationController do
  @moduledoc "The user's notifications (the latest 100), and marking them read."
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Notifications
  alias FireflyWeb.Api.Pagination

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_user)
  plug(:require_scope, "read" when action == :index)
  plug(:require_scope, "notifications:write" when action in [:read, :read_all])

  def index(conn, params) do
    user = current_user(conn)

    conn
    |> put_resp_header("x-unread-count", to_string(Notifications.unread_notification_count(user)))
    |> Pagination.render(Notifications.notifications_for(user), params, &data/1)
  end

  def read(conn, %{"id" => id}) do
    with %{} = notification <- Notifications.get_notification(current_user(conn), int(id) || 0),
         {:ok, notification} <- Notifications.mark_notification_read(notification) do
      ok(conn, data(notification))
    end
  end

  def read_all(conn, _params) do
    Notifications.mark_all_notifications_read(current_user(conn))
    no_content(conn)
  end

  defp data(notification) do
    notification
    |> Map.take([
      :id,
      :kind,
      :subject,
      :body,
      :url,
      :thread_id,
      :post_id,
      :conversation_id,
      :inserted_at
    ])
    |> Map.put(:read, notification.read_at != nil)
  end
end
