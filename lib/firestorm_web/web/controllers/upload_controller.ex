defmodule FirestormWeb.Web.UploadController do
  @moduledoc """
  Serves uploads (see `FirestormWeb.Uploads`) to viewers who may see them:
  an upload in a post only to those who may read the post, in a private
  message only to its participants. Others get a 404, as for a missing
  file.

  Images are shown inline; other files (PDFs, text) download as
  attachments. Either way the browser is told not to guess the type and
  not to run anything in it.
  """
  use FirestormWeb.Web, :controller

  alias FirestormWeb.Uploads
  alias FirestormWeb.Uploads.{Storage, Upload}

  @doc "The uploaded file."
  def show(conn, %{"token" => token}), do: serve(conn, token, :original)

  @doc "The upload's thumbnail."
  def thumbnail(conn, %{"token" => token}), do: serve(conn, token, :thumbnail)

  @doc "An avatar, by its upload id (avatars are public; see `User.avatar_url/2`)."
  def avatar(conn, %{"id" => id}) do
    case Uploads.get_avatar(id) do
      %Upload{} = upload -> send_upload(conn, upload, Uploads.key(upload))
      nil -> not_found(conn)
    end
  end

  defp serve(conn, token, variant) do
    with %Upload{} = upload <- Uploads.get_by_token(token),
         true <- Uploads.readable?(upload, conn.assigns.current_user),
         {:ok, key} <- key(upload, variant) do
      send_upload(conn, upload, key)
    else
      _missing_or_forbidden -> not_found(conn)
    end
  end

  defp not_found(conn),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not found")

  defp key(upload, :original), do: {:ok, Uploads.key(upload)}

  defp key(%Upload{thumbnail: true} = upload, :thumbnail),
    do: {:ok, Uploads.thumbnail_key(upload)}

  defp key(upload, :thumbnail), do: {:ok, Uploads.key(upload)}

  defp send_upload(conn, upload, key) do
    disposition = disposition(upload)

    conn =
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      # Access can change (a post is hidden, a category restricted), so
      # nothing is cached for long, nor by shared caches.
      |> put_resp_header("cache-control", "private, max-age=300")

    case Storage.locate(key, upload.content_type, disposition) do
      {:file, path} ->
        if File.regular?(path) do
          conn
          |> put_resp_header("content-disposition", disposition)
          |> put_resp_content_type(upload.content_type, nil)
          |> send_file(200, path)
        else
          not_found(conn)
        end

      {:redirect, url} ->
        redirect(conn, external: url)
    end
  end

  defp disposition(upload) do
    type = if Upload.image?(upload), do: "inline", else: "attachment"
    ~s(#{type}; filename="#{upload.filename}")
  end
end
