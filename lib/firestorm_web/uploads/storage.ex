defmodule FirestormWeb.Uploads.Storage do
  @moduledoc """
  Where uploaded files live, chosen by `FIREFLY_UPLOAD_STORAGE`: `local`
  (the default; `FirestormWeb.Uploads.Storage.Local`, a directory on disk)
  or `s3` (`FirestormWeb.Uploads.Storage.S3`, a private bucket).

  Files are only ever handed out by `FirestormWeb.Web.UploadController`,
  after it checks the viewer may see them: the local backend sends the
  file, S3 redirects to a link that expires in minutes.
  """

  @typedoc "A stored file's name in the backend, e.g. `original/ab/abcd....png`."
  @type key :: String.t()

  @typedoc "How the controller hands the file out."
  @type location :: {:file, Path.t()} | {:redirect, String.t()}

  @doc "Stores `data` under `key`."
  @callback put(key, data :: binary, content_type :: String.t()) :: :ok | {:error, term}

  @doc "Removes `key`; removing a missing file is fine."
  @callback delete(key) :: :ok | {:error, term}

  @doc "Where to fetch `key`, served as `content_type` with `disposition`."
  @callback locate(key, content_type :: String.t(), disposition :: String.t()) :: location

  @doc "The configured backend."
  def backend do
    case Application.get_env(:firestorm_web, FirestormWeb.Uploads, [])[:storage] do
      :s3 -> FirestormWeb.Uploads.Storage.S3
      _local -> FirestormWeb.Uploads.Storage.Local
    end
  end

  def put(key, data, content_type), do: backend().put(key, data, content_type)
  def delete(key), do: backend().delete(key)
  def locate(key, content_type, disposition), do: backend().locate(key, content_type, disposition)
end
