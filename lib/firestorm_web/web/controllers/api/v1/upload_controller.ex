defmodule FirestormWeb.Web.Api.V1.UploadController do
  @moduledoc """
  `POST /api/v1/uploads`: a multipart `file` upload, through the same
  checks, processing and limits as the composer's (see
  `FirestormWeb.Uploads`). Answers the upload's `url` and the `markdown`
  that shows it in a post; it's attached when a post or message using it
  is saved.
  """
  use FirestormWeb.Web, :controller

  alias FirestormWeb.{RateLimit, Uploads}

  plug(FirestormWeb.Web.Plugs.RequireApiUser)

  def create(conn, %{"file" => %Plug.Upload{path: path, filename: filename}}) do
    case Uploads.create(conn.assigns.current_user, path, filename) do
      {:ok, upload} ->
        conn
        |> put_status(201)
        |> json(%{
          data: %{
            url: Uploads.url(upload),
            markdown: Uploads.markdown(upload),
            content_type: upload.content_type,
            size: upload.size
          }
        })

      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{"error" => RateLimit.message()})

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => message})
    end
  end

  def create(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{"error" => "a file is required"})
end
