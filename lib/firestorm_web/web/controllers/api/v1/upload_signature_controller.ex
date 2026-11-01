defmodule FirestormWeb.Web.Api.V1.UploadSignatureController do
  use FirestormWeb.Web, :controller

  alias FirestormWeb.{RateLimit, Uploads}

  plug(FirestormWeb.Web.Plugs.RequireApiUser)

  def create(conn, %{"upload" => %{"filename" => filename, "mimetype" => mimetype}}) do
    with :ok <- RateLimit.check_upload(conn.assigns.current_user),
         {:ok, signature} <- Uploads.sign(filename, mimetype) do
      conn
      |> put_status(201)
      |> render(:show, upload_signature: signature)
    else
      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{"error" => RateLimit.message()})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => reason})
    end
  end
end
