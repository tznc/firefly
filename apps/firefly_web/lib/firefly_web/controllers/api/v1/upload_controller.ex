defmodule FireflyWeb.Api.V1.UploadController do
  @moduledoc """
  `POST /api/v1/uploads`: a multipart `file` upload, through the same
  checks, processing and limits as the composer's (see
  `Firefly.Uploads`). Answers the upload's `url` and the `markdown`
  that shows it in a post; it's attached when a post or message using it
  is saved.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Uploads

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "uploads:write")

  def create(conn, %{"file" => %Plug.Upload{path: path, filename: filename} = file}) do
    with {:ok, upload} <-
           Uploads.create(current_user(conn), path, filename, claimed_type: file.content_type) do
      ok(
        conn,
        %{
          url: Uploads.url(upload),
          markdown: Uploads.markdown(upload),
          content_type: upload.content_type,
          size: upload.size
        },
        201
      )
    end
  end

  def create(_conn, _params), do: {:error, "a file is required"}
end
