defmodule FirestormWeb.Web.Login do
  @moduledoc """
  Finishing a login in a controller, however the user proved who they are
  (a password, a social login, OpenID Connect, DiscourseConnect): suspended
  users are told why (only once they've proven who they are); anyone else
  gets a fresh session.
  """

  use FirestormWeb.Web, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias FirestormWeb.Penalties
  alias FirestormWeb.Forums.User

  @doc "Logs `user` in, or sends them back to `failure_path` if they're suspended."
  def complete(conn, %User{} = user, failure_path) do
    if User.suspended?(user),
      do: fail(conn, failure_path, Penalties.suspended_message(user)),
      else: log_in(conn, user)
  end

  defp log_in(conn, user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:current_user, user.id)
    |> put_session(:live_socket_id, FirestormWeb.Web.Session.live_socket_id(user))
    |> put_flash(:info, "Successfully authenticated.")
    |> redirect(to: ~p"/")
  end

  @doc "Sends the browser back to `path` with `reason` (a message or a changeset)."
  def fail(conn, path, reason) do
    conn
    |> put_flash(:error, error_message(reason))
    |> redirect(to: path)
  end

  defp error_message(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(&FirestormWeb.Web.CoreComponents.translate_error/1)
      |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)

    "Login unsuccessful: #{details}"
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(_reason), do: "Login unsuccessful"
end
