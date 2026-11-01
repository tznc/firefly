defmodule FirestormWeb.Web.Api.V1.PostController do
  use FirestormWeb.Web, :controller

  alias FirestormWeb.{Forums, Posting}

  plug(FirestormWeb.Web.Plugs.RequireApiUser)

  def create(conn, %{"post" => post_params, "thread_id" => thread_id}) do
    user = conn.assigns.current_user

    with %{} = thread <- Forums.get_thread(thread_id),
         :ok <- Posting.check(user, thread),
         {:ok, post} <- Forums.create_post(thread, user, %{body: post_params["body"]}) do
      conn
      |> put_status(201)
      |> render(:show, post: post)
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{"error" => "Thread not found"})

      # A thread the user can't read doesn't exist, as far as they know.
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{"error" => "Thread not found"})

      {:error, :closed} ->
        conn |> put_status(:forbidden) |> json(%{"error" => Posting.message(:closed)})

      {:error, {penalty, _until} = reason} when penalty in [:silenced, :suspended] ->
        conn |> put_status(:forbidden) |> json(%{"error" => Posting.message(reason)})

      {:error, :unconfirmed} ->
        conn |> put_status(:forbidden) |> json(%{"error" => Posting.message(:unconfirmed)})

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{"error" => Posting.message(:rate_limited)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{"errors" => Ecto.Changeset.traverse_errors(changeset, &translate_error/1)})
    end
  end

  defp translate_error(error), do: FirestormWeb.Web.CoreComponents.translate_error(error)
end
