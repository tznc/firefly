defmodule Firefly.Backups.Store do
  @moduledoc """
  Where backups are kept (the `Firefly.Backups` config's `:storage`):

    * `:local` (default): the `:dir` directory (`FIREFLY_BACKUP_DIR`,
      `backups` under the working directory by default);
    * `:s3` (`FIREFLY_BACKUP_STORAGE=s3`): the uploads' S3 bucket
      (`FIREFLY_AWS_*`), under the `:s3_prefix` (`FIREFLY_BACKUP_S3_PREFIX`,
      default `backups/`). The bucket is private: downloads are links
      that expire in minutes.

  Backups are named by `Firefly.Backups`; only such names are accepted, so
  a name can't reach outside the directory or prefix.
  """

  alias Firefly.Uploads.AWS.SigV4

  @name ~r/\A[a-z0-9][a-z0-9._-]*\.tar\.gz\z/
  @link_seconds 300

  @doc "Whether `name` is a backup's name."
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc "`:local` or `:s3`."
  def storage, do: config()[:storage] || :local

  @doc "The local directory (used for local storage, and as the staging area)."
  def dir, do: Path.expand(config()[:dir] || "backups")

  defp prefix, do: config()[:s3_prefix] || "backups/"

  defp config, do: Application.get_env(:firefly, Firefly.Backups, [])

  @doc "The backups, newest first: `[%{name, size, modified_at}]`."
  def list do
    case storage() do
      :local -> list_local()
      :s3 -> list_s3()
    end
  end

  defp list_local do
    for name <- File.ls!(ensure_dir()),
        valid_name?(name),
        %File.Stat{size: size, mtime: mtime} <- [File.stat!(Path.join(dir(), name), time: :posix)] do
      %{name: name, size: size, modified_at: DateTime.from_unix!(mtime)}
    end
    |> Enum.sort_by(& &1.name, :desc)
  end

  defp list_s3 do
    {url, headers} = SigV4.signed("GET", "", query: [{"list-type", "2"}, {"prefix", prefix()}])

    case :hackney.request(:get, url, headers, "", recv_timeout: 30_000, pool: false) do
      {:ok, 200, _headers, body} ->
        ~r/<Contents>(.*?)<\/Contents>/s
        |> Regex.scan(body, capture: :all_but_first)
        |> Enum.map(fn [item] -> s3_entry(item) end)
        |> Enum.filter(&valid_name?(&1.name))
        |> Enum.sort_by(& &1.name, :desc)

      _error ->
        []
    end
  end

  defp s3_entry(item) do
    field = fn tag -> Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, item, capture: :all_but_first) end
    [key] = field.("Key")
    [size] = field.("Size")
    {:ok, modified_at, _} = DateTime.from_iso8601(hd(field.("LastModified")))

    %{
      name: String.replace_prefix(key, prefix(), ""),
      size: String.to_integer(size),
      modified_at: modified_at
    }
  end

  @doc "Stores the file at `path` as `name` (moving it, when local)."
  def put(path, name) do
    case storage() do
      :local ->
        ensure_dir()
        File.rename(path, Path.join(dir(), name))

      :s3 ->
        {url, headers} =
          SigV4.signed("PUT", prefix() <> name,
            headers: [{"content-type", "application/gzip"}],
            payload_hash: "UNSIGNED-PAYLOAD"
          )

        headers = [{"content-length", to_string(File.stat!(path).size)} | headers]
        result = request(:put, url, headers, {:file, path})
        File.rm(path)
        result
    end
  end

  @doc """
  A local path to the backup `name`, and whether it's a temporary copy the
  caller deletes: `{:ok, path, temporary?}`.
  """
  def fetch(name) do
    case storage() do
      :local ->
        path = Path.join(dir(), name)
        if File.regular?(path), do: {:ok, path, false}, else: {:error, "no such backup"}

      :s3 ->
        path =
          Path.join(System.tmp_dir!(), "firefly-#{System.unique_integer([:positive])}-#{name}")

        url = SigV4.presigned_url(prefix() <> name, @link_seconds)

        case :hackney.request(:get, url, [], "", recv_timeout: 300_000, pool: false) do
          {:ok, 200, _headers, body} ->
            File.write!(path, body)
            {:ok, path, true}

          _error ->
            {:error, "couldn't download the backup from S3"}
        end
    end
  end

  @doc "How to hand `name` to a downloader: `{:file, path}` or `{:redirect, url}`."
  def locate(name) do
    case storage() do
      :local ->
        {:file, Path.join(dir(), name)}

      :s3 ->
        {:redirect,
         SigV4.presigned_url(prefix() <> name, @link_seconds, %{
           "response-content-disposition" => ~s{attachment; filename="#{name}"}
         })}
    end
  end

  @doc "Deletes the backup `name`."
  def delete(name) do
    case storage() do
      :local ->
        case File.rm(Path.join(dir(), name)) do
          {:error, :enoent} -> :ok
          result -> result
        end

      :s3 ->
        {url, headers} = SigV4.signed("DELETE", prefix() <> name, [])
        request(:delete, url, headers, "")
    end
  end

  defp request(method, url, headers, body) do
    case :hackney.request(method, url, headers, body, recv_timeout: 300_000, pool: false) do
      {:ok, status, _headers, _body} when status in 200..299 -> :ok
      {:ok, status, _headers} when status in 200..299 -> :ok
      {:ok, status, _headers, body} -> {:error, "S3 answered #{status}: #{body}"}
      {:ok, status, _headers} -> {:error, "S3 answered #{status}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp ensure_dir do
    File.mkdir_p!(dir())
    dir()
  end
end
