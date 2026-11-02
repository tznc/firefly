defmodule FireflyWeb.Session do
  @moduledoc """
  Helpers for the logged-in user stored in the session (`"current_user"` holds
  the user id). A deleted or suspended account's sessions resolve to nobody.
  """

  alias Firefly.Forums
  alias Firefly.Forums.User

  @doc "The current user for a conn, from its assigns or its session."
  def current_user(%Plug.Conn{assigns: %{current_user: user}}), do: user

  def current_user(%Plug.Conn{} = conn) do
    conn
    |> Plug.Conn.get_session(:current_user)
    |> user_from_id()
  end

  @doc "Loads the user for a session user id, or nil."
  def user_from_id(nil), do: nil

  def user_from_id(id) do
    case Forums.get_user(id) do
      %{deleted_at: nil} = user -> if User.suspended?(user), do: nil, else: user
      _missing_or_deleted -> nil
    end
  end

  @doc "The id LiveView sockets of `user` share (see `Firefly.UserSessions`)."
  defdelegate live_socket_id(user), to: Firefly.UserSessions

  @doc """
  Makes every open page of `user` pick up a change to their account (see
  `Firefly.UserSessions.reload_pages/1` and `FireflyWeb.UserAuth`).
  """
  defdelegate reload_pages(user), to: Firefly.UserSessions

  def logged_in?(conn), do: !!current_user(conn)

  def admin?(conn) do
    case current_user(conn) do
      nil -> false
      user -> Forums.admin?(user)
    end
  end
end
