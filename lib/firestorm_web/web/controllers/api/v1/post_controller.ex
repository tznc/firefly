defmodule FirestormWeb.Web.Api.V1.PostController do
  use FirestormWeb.Web, :controller
  require Logger
  alias FirestormWeb.Forums

  def create(conn, %{"post" => post_params, "thread_id" => thread_id}) do
    with thread when not is_nil(thread) <- Forums.get_thread(thread_id),
         user when not is_nil(user) <- conn.assigns[:current_user],
         {:ok, post} <- Forums.create_post(thread, user, %{body: post_params["body"]}) do
      conn
      |> put_status(201)
      |> render(:show, post: post)
    else
      error ->
        Logger.debug("Failed to create post via API: #{inspect(error)}")

        conn
        |> put_status(:unprocessable_entity)
        # FIXME: Send back errors that are meaningful
        |> json(%{"error" => "Failed to create post"})
    end
  end
end
