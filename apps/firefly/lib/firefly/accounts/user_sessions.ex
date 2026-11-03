defmodule Firefly.Accounts.UserSessions do
  @moduledoc """
  A member's open pages: LiveView sockets share `live_socket_id/1` (stored
  as `"live_socket_id"` in the session at login), so a change to their
  account can reach them all.
  """

  alias Firefly.{Endpoint, Notifications}
  alias Firefly.Accounts.User

  @doc "The id LiveView sockets of `user` share."
  def live_socket_id(%{id: id}), do: "users_sockets:#{id}"

  @doc """
  Makes every open page of `user` pick up a change to their account (a
  penalty, deletion): sockets sharing `live_socket_id/1` are disconnected,
  and pages whose session predates it (no socket id) reload themselves on
  the user's notification topic.
  """
  def reload_pages(%User{} = user) do
    Endpoint.broadcast(live_socket_id(user), "disconnect", %{})

    Phoenix.PubSub.broadcast(
      Firefly.PubSub,
      Notifications.notifications_topic(user.id),
      :account_changed
    )
  end
end
