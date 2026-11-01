defmodule FirestormWeb.Web.Session do
  @moduledoc """
  Helpers for the logged-in user stored in the session (`"current_user"` holds
  the user id).
  """

  alias FirestormWeb.Forums

  @doc "The current user for a conn, from its assigns or its session."
  def current_user(%Plug.Conn{assigns: %{current_user: user}}), do: user

  def current_user(%Plug.Conn{} = conn) do
    conn
    |> Plug.Conn.get_session(:current_user)
    |> user_from_id()
  end

  @doc "Loads the user for a session user id, or nil."
  def user_from_id(nil), do: nil
  def user_from_id(id), do: Forums.get_user(id)

  def logged_in?(conn), do: !!current_user(conn)

  def admin?(conn) do
    case current_user(conn) do
      nil -> false
      user -> Forums.admin?(user)
    end
  end
end
