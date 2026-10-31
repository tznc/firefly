defmodule FirestormWeb.Web.Api.V1.UploadSignatureController do
  use FirestormWeb.Web, :controller

  def create(conn, %{"upload" => %{"filename" => filename, "mimetype" => mimetype}}) do
    {:ok, signature} = FirestormWeb.Uploads.sign(filename, mimetype)

    conn
    |> put_status(201)
    |> render(:show, upload_signature: signature)
  end
end
