defmodule FirestormWeb.Uploads.Storage.S3 do
  @moduledoc """
  Uploads in an S3 bucket (`FIREFLY_UPLOAD_STORAGE=s3`, with the
  `FIREFLY_AWS_*` settings). Objects are private: the server writes them
  with signed requests, and viewers get a presigned link valid for a few
  minutes, after `FirestormWeb.Web.UploadController` checks they may see
  the file.
  """

  @behaviour FirestormWeb.Uploads.Storage

  alias FirestormWeb.Uploads.AWS.SigV4

  # How long a link handed to a viewer works.
  @link_seconds 300

  @impl true
  def put(key, data, content_type) do
    {url, headers} = SigV4.request("PUT", key, data, [{"content-type", content_type}])
    send_request(:put, url, headers, data)
  end

  @impl true
  def delete(key) do
    {url, headers} = SigV4.request("DELETE", key)
    send_request(:delete, url, headers, "")
  end

  @impl true
  def locate(key, content_type, disposition) do
    {:redirect,
     SigV4.presigned_url(key, @link_seconds, %{
       "response-content-type" => content_type,
       "response-content-disposition" => disposition
     })}
  end

  defp send_request(method, url, headers, body) do
    case :hackney.request(method, url, headers, body, recv_timeout: 30_000, pool: false) do
      {:ok, status, _headers, _body} when status in 200..299 -> :ok
      {:ok, status, _headers} when status in 200..299 -> :ok
      {:ok, status, _headers, body} -> {:error, "S3 answered #{status}: #{body}"}
      {:ok, status, _headers} -> {:error, "S3 answered #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end
end
