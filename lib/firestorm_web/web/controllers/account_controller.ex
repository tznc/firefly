defmodule FirestormWeb.Web.AccountController do
  @moduledoc """
  Downloads the current user's data, and deletes their account (see
  `FirestormWeb.AccountExport` and `FirestormWeb.AccountDeletion`). Plain
  requests rather than LiveView events, so the download streams as a file
  and deletion can clear the session cookie.
  """
  use FirestormWeb.Web, :controller

  alias FirestormWeb.{AccountDeletion, AccountExport, RateLimit}

  plug(:require_user)

  def export(conn, _params) do
    user = conn.assigns.current_user

    case RateLimit.check_export(user) do
      :ok ->
        send_download(conn, {:binary, AccountExport.to_json(user)},
          filename: "firefly-#{user.username}-#{Date.utc_today()}.json",
          content_type: "application/json"
        )

      {:error, :rate_limited} ->
        conn |> put_flash(:error, RateLimit.message()) |> redirect(to: ~p"/settings/account")
    end
  end

  def delete(conn, params) do
    case AccountDeletion.delete_account(conn.assigns.current_user, params["confirmation"]) do
      {:ok, _anonymized} ->
        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_flash(
          :info,
          "Your account was deleted. Your posts stay, credited to a deleted user."
        )
        |> redirect(to: ~p"/")

      {:error, reason} ->
        conn
        |> put_flash(:error, AccountDeletion.message(reason))
        |> redirect(to: ~p"/settings/account")
    end
  end

  defp require_user(conn, _opts) do
    if conn.assigns.current_user do
      conn
    else
      conn
      |> put_flash(:error, "You must be logged in to access this page.")
      |> redirect(to: ~p"/categories")
      |> halt()
    end
  end
end
