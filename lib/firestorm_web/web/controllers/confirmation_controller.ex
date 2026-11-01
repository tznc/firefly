defmodule FirestormWeb.Web.ConfirmationController do
  use FirestormWeb.Web, :controller

  alias FirestormWeb.{EmailConfirmation, Forums, RateLimit}

  def confirm(conn, %{"token" => token}) do
    case EmailConfirmation.confirm(token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Thanks, your email address is confirmed.")
        |> redirect(to: ~p"/")

      {:error, _} ->
        conn
        |> put_flash(:error, "That confirmation link is invalid or has expired.")
        |> redirect(to: ~p"/")
    end
  end

  def resend(conn, _params) do
    user = conn.assigns[:current_user] || Forums.get_user(get_session(conn, :current_user) || 0)

    cond do
      is_nil(user) ->
        conn |> put_flash(:error, "You must be logged in.") |> redirect(to: ~p"/login")

      Forums.User.confirmed?(user) ->
        conn
        |> put_flash(:info, "Your email address is already confirmed.")
        |> redirect(to: ~p"/")

      RateLimit.check_email(user) == :ok and EmailConfirmation.deliver(user) == :ok ->
        conn
        |> put_flash(:info, "We sent a new confirmation link to #{user.email}.")
        |> redirect(to: ~p"/")

      true ->
        conn
        |> put_flash(:error, "We couldn't send a confirmation email right now. Try again later.")
        |> redirect(to: ~p"/")
    end
  end
end
