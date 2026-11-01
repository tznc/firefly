defmodule FirestormWeb.Web.UserController do
  @moduledoc "Old profile edit links (`/users/:id/edit`) lead to the settings page."
  use FirestormWeb.Web, :controller

  def edit(conn, %{"id" => id}) do
    case conn.assigns.current_user do
      nil ->
        conn
        |> put_flash(:error, "You must be logged in to access this page.")
        |> redirect(to: ~p"/categories")

      %{id: user_id} ->
        if to_string(user_id) == id,
          do: redirect(conn, to: ~p"/settings/profile"),
          else:
            conn
            |> put_flash(:error, "You can only edit your own profile.")
            |> redirect(to: ~p"/users/#{id}")
    end
  end
end
