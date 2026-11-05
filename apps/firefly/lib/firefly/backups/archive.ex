defmodule Firefly.Backups.Archive do
  @moduledoc """
  A backup's file: a gzipped tar of `meta.json` (format, Firefly version,
  latest migration, when, the site's title), `database.dump` (`pg_dump
  --format=custom`, uncompressed inside the gzip) and, optionally, the
  local upload directory under `uploads/`.

  Runs PostgreSQL's own client tools (`pg_dump`, `pg_restore`), which must
  be the server's major version or newer: they're taken from `:pg_bin_dir` (the
  `Firefly.Backups` config, `FIREFLY_PG_BIN_DIR`), else the newest
  `/usr/lib/postgresql/<version>/bin` (where Debian and Ubuntu install
  each version), else the `PATH`. The database is the repo's unless a
  `:database` name is given.
  """

  alias Firefly.Repo

  @format 1

  @doc """
  Writes a backup to `path`. `meta` is added to `meta.json`; with
  `uploads_dir`, that directory goes in too. `log` gets progress lines.
  """
  # Sobelow: removes the work directory this function created.
  # sobelow_skip ["Traversal.FileModule"]
  def build(path, meta, opts) do
    log = opts[:log] || fn _line -> :ok end
    work = tmp_dir("backup")

    try do
      dump = Path.join(work, "database.dump")
      log.("Dumping the database")

      with :ok <- pg_dump(dump, opts) do
        meta = Map.merge(meta, %{format: @format, migration: latest_migration(opts)})

        entries =
          [{~c"meta.json", Jason.encode!(meta)}, {~c"database.dump", to_charlist(dump)}] ++
            uploads(opts[:uploads_dir], log)

        log.("Compressing")

        case :erl_tar.create(to_charlist(path), entries, [:compressed]) do
          :ok -> :ok
          {:error, reason} -> {:error, "couldn't write the archive: #{inspect(reason)}"}
        end
      end
    after
      File.rm_rf(work)
    end
  end

  defp uploads(nil, _log), do: []

  defp uploads(dir, log) do
    if File.dir?(dir) do
      files = Enum.filter(Path.wildcard(Path.join(dir, "**/*")), &File.regular?/1)

      log.("Adding #{length(files)} uploaded files")

      for file <- files,
          do: {to_charlist(Path.join("uploads", Path.relative_to(file, dir))), to_charlist(file)}
    else
      []
    end
  end

  @doc "A backup's `meta.json`."
  def meta(path) do
    case :erl_tar.extract(to_charlist(path), [:compressed, :memory, {:files, [~c"meta.json"]}]) do
      {:ok, [{_name, json}]} -> Jason.decode(json)
      {:ok, []} -> {:error, "not a Firefly backup (no meta.json)"}
      {:error, reason} -> {:error, "unreadable backup: #{inspect(reason)}"}
    end
  end

  @doc """
  Unpacks the backup at `path` into a new directory: `{:ok, dir, meta}`.
  The caller removes `dir`.
  """
  # Sobelow: removes the directory this function created.
  # sobelow_skip ["Traversal.FileModule"]
  def extract(path) do
    dir = tmp_dir("restore")

    with {:ok, meta} <- meta(path),
         :ok <- check_format(meta),
         :ok <- untar(path, dir) do
      {:ok, dir, meta}
    else
      error ->
        File.rm_rf(dir)
        error
    end
  end

  defp check_format(%{"format" => @format}), do: :ok
  defp check_format(_meta), do: {:error, "this backup's format isn't supported"}

  defp untar(path, dir) do
    case :erl_tar.extract(to_charlist(path), [:compressed, {:cwd, to_charlist(dir)}]) do
      :ok -> :ok
      {:error, reason} -> {:error, "unreadable backup: #{inspect(reason)}"}
    end
  end

  ## PostgreSQL

  @doc "Dumps the database to `path` (custom format)."
  def pg_dump(path, opts \\ []),
    do: pg("pg_dump", ["--format=custom", "--compress=0", "--no-owner", "--file", path], opts)

  @doc """
  Restores the dump at `path` over the database: everything in the dump is
  dropped and recreated, in one transaction (all or nothing).
  """
  def pg_restore(path, opts \\ []) do
    pg(
      "pg_restore",
      ~w(--clean --if-exists --no-owner --no-acl --single-transaction --exit-on-error) ++
        ["--dbname", database(opts), path],
      opts
    )
  end

  # Sobelow: runs pg_dump/pg_restore by path with an argument list, no shell.
  # sobelow_skip ["CI.System"]
  defp pg(tool, args, opts) do
    {output, status} =
      System.cmd(executable(tool), args, env: env(opts), stderr_to_stdout: true)

    if status == 0, do: :ok, else: {:error, "#{tool} failed: #{String.trim(output)}"}
  rescue
    error in ErlangError -> {:error, "#{tool} couldn't run: #{inspect(error.original)}"}
  end

  @doc "Where `tool` (`pg_dump`, `pg_restore`) is run from (see the moduledoc)."
  def executable(tool) do
    dir =
      Application.get_env(:firefly, Firefly.Backups, [])[:pg_bin_dir] ||
        "/usr/lib/postgresql/*/bin"
        |> Path.wildcard()
        |> Enum.filter(&File.exists?(Path.join(&1, tool)))
        |> Enum.max_by(&version/1, fn -> nil end)

    if dir, do: Path.join(dir, tool), else: System.find_executable(tool) || tool
  end

  defp version(dir) do
    case Integer.parse(dir |> Path.dirname() |> Path.basename()) do
      {n, ""} -> n
      _ -> 0
    end
  end

  # libpq reads the connection from the environment, so no password is in
  # the command line.
  defp env(opts) do
    config = Repo.config()

    [
      {"PGHOST", to_string(config[:hostname] || config[:socket_dir] || "localhost")},
      {"PGPORT", to_string(config[:port] || 5432)},
      {"PGUSER", to_string(config[:username] || "")},
      {"PGPASSWORD", to_string(config[:password] || "")},
      {"PGDATABASE", database(opts)},
      {"PGSSLMODE", if(config[:ssl], do: "require", else: "prefer")}
    ]
  end

  @doc "The database backed up or restored: `:database`, else the repo's."
  def database(opts), do: opts[:database] || Repo.config()[:database]

  defp latest_migration(opts) do
    %{rows: rows} =
      query(opts, "SELECT max(version) FROM schema_migrations", [])

    case rows do
      [[version]] -> version
      _ -> nil
    end
  rescue
    # An empty database has no migrations table yet.
    Postgrex.Error -> nil
  end

  @doc """
  Runs `fun` with a repo connected to the database `opts` name (see
  `database/1`), as a dynamic repo (`Firefly.Repo.put_dynamic_repo/1`):
  migrations and queries reach that database, whatever the app's own
  pool is busy with.
  """
  def with_repo(opts, fun) do
    {:ok, pid} =
      Repo.start_link(
        name: nil,
        database: database(opts),
        pool: DBConnection.ConnectionPool,
        pool_size: 2
      )

    previous = Repo.get_dynamic_repo()

    try do
      Repo.put_dynamic_repo(pid)
      fun.(pid)
    after
      Repo.put_dynamic_repo(previous)
      Supervisor.stop(pid)
    end
  end

  # Sobelow: callers pass fixed SQL; values are parameters.
  # sobelow_skip ["SQL.Query"]
  defp query(opts, sql, params), do: with_repo(opts, fn _ -> Repo.query!(sql, params) end)

  # Sobelow: a new directory under the system temporary directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp tmp_dir(kind) do
    dir = Path.join(System.tmp_dir!(), "firefly-#{kind}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
