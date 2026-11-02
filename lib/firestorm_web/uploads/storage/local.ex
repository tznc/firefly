defmodule FirestormWeb.Uploads.Storage.Local do
  @moduledoc """
  Uploads in a directory on the server's disk: `FIREFLY_UPLOAD_DIR`
  (`uploads` under the working directory by default; mount a volume there
  in Docker). The directory isn't served as static files: every request
  goes through `FirestormWeb.Web.UploadController`'s access check.
  """

  @behaviour FirestormWeb.Uploads.Storage

  @impl true
  def put(key, data, _content_type) do
    path = path(key)
    # Written aside and renamed, so a reader never sees half a file.
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, data) do
      File.rename(temporary, path)
    end
  end

  @impl true
  def delete(key) do
    case File.rm(path(key)) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  @impl true
  def locate(key, _content_type, _disposition), do: {:file, path(key)}

  @doc "The directory uploads are kept in."
  def root do
    Application.get_env(:firestorm_web, FirestormWeb.Uploads, [])[:local_dir] || "uploads"
  end

  # Keys are built by FirestormWeb.Uploads from a hex digest and a known
  # extension, never from user input, so they can't climb out of the root.
  defp path(key), do: Path.join(Path.expand(root()), key)
end
