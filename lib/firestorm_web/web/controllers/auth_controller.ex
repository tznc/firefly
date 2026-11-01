defmodule FirestormWeb.Web.AuthController do
  @moduledoc """
  Handles the OAuth/identity callbacks from Ueberauth and logging out. The
  login pages themselves are LiveViews (`AuthLive.Login`, `AuthLive.Identity`).
  """
  use FirestormWeb.Web, :controller

  alias FirestormWeb.{Forums, Penalties, RateLimit}
  alias FirestormWeb.Forums.User

  # Ueberauth redirects GET /auth/:provider for OAuth providers before this
  # action runs; we only get here for unknown providers.
  def request(conn, _params) do
    conn
    |> put_flash(:error, "Unknown login provider.")
    |> redirect(to: ~p"/login")
  end

  def delete(conn, _params) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_flash(:info, "You have been logged out!")
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_failure: _fails}} = conn, _params) do
    conn
    |> put_flash(:error, "Failed to authenticate.")
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: %{provider: :github} = auth}} = conn, _params) do
    %{name: name, nickname: nickname, email: email} = auth.info
    info = %{uid: auth.uid, name: name, nickname: nickname, email: email}

    case Forums.login_or_register_from_github(info) do
      {:ok, user} -> ok_login(conn, user, ~p"/login")
      {:error, reason} -> failed_login(conn, ~p"/", reason)
    end
  end

  def callback(%{assigns: %{ueberauth_auth: %{provider: :identity}}} = conn, params) do
    user_params = params["user"] || %{}

    with :ok <- RateLimit.check_login(user_params["username"], conn.remote_ip),
         {:ok, user} <-
           Forums.authenticate_by_password(user_params["username"], user_params["password"]) do
      ok_login(conn, user, ~p"/auth/identity")
    else
      {:error, :rate_limited} -> failed_login(conn, ~p"/auth/identity", RateLimit.message())
      {:error, reason} -> failed_login(conn, ~p"/auth/identity", reason)
    end
  end

  # Suspended users are told why (only once they've proven who they are).
  defp ok_login(conn, user, failure_path) do
    if User.suspended?(user),
      do: failed_login(conn, failure_path, Penalties.suspended_message(user)),
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

  defp failed_login(conn, path, reason) do
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
