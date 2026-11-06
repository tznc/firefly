defmodule Firefly.Uploads.ScanWorker do
  @moduledoc """
  Has ClamAV scan a new upload's stored file (see `Firefly.Uploads.Scanner`),
  then serves or quarantines every pending upload of that content (see
  `Firefly.Uploads.scanned/2`). While clamd can't be reached the job is
  retried with backoff, and the upload stays unserved.
  """

  # Unique per stored file while waiting: uploads sharing it are decided together.
  use Oban.Worker,
    queue: :default,
    max_attempts: 20,
    unique: [keys: [:sha256], states: [:available, :scheduled, :retryable]]

  require Logger

  alias Firefly.{Repo, Uploads}
  alias Firefly.Uploads.{Scanner, Upload}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"upload_id" => id}}) do
    with %Upload{scan_status: "pending"} = upload <- Repo.get(Upload, id),
         {:ok, data} <- Uploads.contents(upload) do
      case Scanner.scan(data) do
        :clean ->
          Uploads.scanned(upload, :clean)

        {:infected, signature} ->
          Uploads.scanned(upload, {:infected, signature})

        {:error, reason} ->
          Logger.warning("Scanning upload #{id} failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      # Gone, or already decided (another upload of the same file).
      nil -> :ok
      %Upload{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
