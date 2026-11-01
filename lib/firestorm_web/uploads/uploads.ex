defmodule FirestormWeb.Uploads do
  @moduledoc """
  Context for file uploads, which go straight from the browser to S3 using a
  presigned POST policy (see `FirestormWeb.Uploads.AWS.UploadSignature`).
  """

  alias FirestormWeb.Uploads.AWS.UploadSignature

  @max_size 10_000_000
  @allowed_types ~w(image/png image/jpeg image/gif image/webp application/pdf text/plain)

  @doc "Largest accepted upload, in bytes."
  def max_size, do: @max_size

  @doc "Accepted MIME types. HTML, SVG and other active content are refused."
  def allowed_types, do: @allowed_types

  def sign(filename, mimetype) when mimetype in @allowed_types do
    {:ok, UploadSignature.signature(file_path(filename), mimetype, @max_size)}
  end

  def sign(_filename, _mimetype), do: {:error, "unsupported file type"}

  defp file_path(filename) do
    "uploads/#{Ecto.UUID.generate()}/#{safe_filename(filename)}"
  end

  @doc false
  def safe_filename(filename) do
    filename
    |> to_string()
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.slice(0, 100)
    |> case do
      name when name in ["", ".", ".."] -> "file"
      name -> name
    end
  end
end
