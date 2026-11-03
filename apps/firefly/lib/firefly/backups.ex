defmodule Firefly.Backups do
  @moduledoc """
  The Backups context: backups of the database (and the local uploads)
  admins make, schedule, download, delete and restore at `/staff/backups`,
  as in Discourse.

  A backup (see `Firefly.Backups.Archive`) is a gzipped tar of a
  `pg_dump` in PostgreSQL's custom format, the uploads directory when
  uploads are stored locally and the `backup_uploads` setting is on
  (uploads in S3 are already durable there), and a `meta.json`. Backups
  are kept locally or in S3 (`Firefly.Backups.Store`). Scheduled backups
  run every `backup_frequency_days` days (0: off), once across nodes; after
  each backup only the newest `backup_keep` are kept.

  Restoring puts the site in read-only mode (`read_only?/0`), restores
  the dump over the database with `pg_restore --clean --if-exists` in one
  transaction, copies the uploads back, runs the migrations the backup
  predates, reloads cached settings and plugins on every node, and lifts
  read-only mode. The admin confirms by typing the site's title. Progress
  is broadcast as it goes (see `Firefly.Backups.Runner`); one backup or
  restore runs at a time per node.

  Read-only mode (also an admin toggle, for maintenance) blocks writes
  app-wide: the posting gate (`Firefly.Moderation.Posting`) refuses, the
  web interface refuses API writes and LiveView events and shows a
  banner, and background jobs, visit tracking and analytics writes wait.
  It's kept in memory on every node (a restore replaces the database it
  would be stored in).

  Downloads are signed links that work for 5 minutes, for the admin who
  asked; creating, downloading, deleting and restoring go to the staff log.
  """

  use Boundary, top_level?: true, check: [out: false], exports: []

  alias Firefly.{Accounts, JobRuns, Plugins, Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Backups.{Archive, Runner, Store}
  alias Firefly.Moderation.StaffLog
  alias Firefly.Uploads.Storage

  @topic "backups"
  @read_only_topic "backups:read_only"
  @download_salt "backup download"
  @download_seconds 300

  @doc "The topic progress is broadcast on (see `Firefly.Backups.Runner`)."
  def topic, do: @topic

  @doc false
  def read_only_topic, do: @read_only_topic

  @doc "Subscribes the caller to backup progress."
  def subscribe, do: Phoenix.PubSub.subscribe(Firefly.PubSub, @topic)

  @doc """
  Subscribes the caller to read-only mode changes: `{:read_only, nil |
  %{reason: text, since: datetime}}`.
  """
  def subscribe_read_only, do: Phoenix.PubSub.subscribe(Firefly.PubSub, @read_only_topic)

  ## Read-only mode

  @doc "Whether the site is read-only now."
  def read_only?, do: Runner.read_only() != nil

  @doc "The read-only state: nil or `%{reason: text, since: datetime}`."
  def read_only, do: Runner.read_only()

  @doc """
  Turns read-only mode on (with a `reason` shown in the banner) or off
  (nil), on every node. As `admin` (logged), or the system's (restores).
  """
  def set_read_only(reason, admin \\ nil) do
    value = reason && %{reason: reason, since: DateTime.utc_now(:second)}
    Runner.put_read_only(value)
    Phoenix.PubSub.broadcast(Firefly.PubSub, @read_only_topic, {:read_only, value})

    if admin,
      do: StaffLog.record(admin, "backup.read_only", {"backup", nil}, %{on: value != nil})

    :ok
  end

  ## Listing and status

  @doc "The backups, newest first: `[%{name, size, modified_at}]`."
  defdelegate list, to: Store

  @doc "`:local` or `:s3` (see `Firefly.Backups.Store`)."
  defdelegate storage, to: Store

  @doc "What's running on this node and its log (see `Firefly.Backups.Runner.status/0`)."
  defdelegate status, to: Runner

  @doc "Whether a backup can include the uploads (they're stored locally)."
  def local_uploads?, do: Storage.backend() == Storage.Local

  ## Making backups

  @doc """
  Starts a backup in the background, as `admin` (nil: scheduled).
  `:ok` or `{:error, :busy}`. Options: `:uploads` (default: the
  `backup_uploads` setting, when uploads are local) and `:database`
  (another database than the repo's, for tests).
  """
  def create(admin, opts \\ []) do
    Runner.run(:backup, fn log ->
      with {:ok, name} <- make_backup(opts, log) do
        log_action(admin, "backup.create", %{name: name})
        prune(log)
        {:ok, name}
      end
    end)
  end

  @doc "Makes a backup now, in the caller (see `create/2`): `{:ok, name}`."
  def make_backup(opts, log \\ fn _line -> :ok end) do
    name = name()
    staging = Path.join(System.tmp_dir!(), "firefly-#{System.unique_integer([:positive])}.tar.gz")

    uploads =
      if Keyword.get(opts, :uploads, SiteSettings.get("backup_uploads")) and local_uploads?(),
        do: Storage.Local.root()

    meta = %{
      title: SiteSettings.get("title"),
      version: to_string(Application.spec(:firefly, :vsn)),
      created_at: DateTime.utc_now(:second),
      uploads: uploads != nil
    }

    log.("Making #{name}")

    result =
      with :ok <-
             Archive.build(staging, meta, Keyword.merge(opts, uploads_dir: uploads, log: log)),
           _ = log.("Storing it (#{storage()})"),
           :ok <- Store.put(staging, name) do
        {:ok, name}
      end

    File.rm(staging)
    result
  end

  defp name do
    title = String.downcase(SiteSettings.get("title"))

    title =
      title |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") |> String.slice(0, 40)

    stamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d-%H%M%S")
    "#{if(title == "", do: "firefly", else: title)}-#{stamp}.tar.gz"
  end

  # Keeps the newest `backup_keep`.
  defp prune(log) do
    for %{name: name} <- Enum.drop(Store.list(), SiteSettings.get("backup_keep")) do
      log.("Removing the old backup #{name}")
      Store.delete(name)
    end
  end

  @doc """
  Makes a scheduled backup when one is due (every `backup_frequency_days`
  days; 0 is off). Run by the scheduler
  (`Firefly.Moderation.TopicTimers.Scheduler`), once across nodes.
  """
  def run_due do
    days = SiteSettings.get("backup_frequency_days")

    # Claimed a little early, so a backup that took a while doesn't push
    # the next one a whole scheduler interval later every time.
    if days > 0 and JobRuns.claim("backups.scheduled", days * 86_400 - 600),
      do: create(nil)

    :ok
  end

  ## Deleting and downloading

  @doc "Deletes the backup `name` as `admin`."
  def delete(name, %User{} = admin) do
    with :ok <- check_name(name),
         :ok <- Store.delete(name) do
      StaffLog.record(admin, "backup.delete", {"backup", nil}, %{name: name})
      :ok
    end
  end

  @doc "A token for `admin` to download `name` with, valid for 5 minutes."
  def download_token(name, %User{id: id}), do: Firefly.Endpoint.sign(@download_salt, {name, id})

  @doc """
  The backup a download `token` is for, if it's still valid and `admin`'s:
  `{:ok, location}` (see `Firefly.Backups.Store.locate/1`), logged.
  """
  def download(token, %User{id: id} = admin) do
    case Firefly.Endpoint.verify(@download_salt, token, max_age: @download_seconds) do
      {:ok, {name, ^id}} ->
        with :ok <- check_name(name) do
          StaffLog.record(admin, "backup.download", {"backup", nil}, %{name: name})
          {:ok, name, Store.locate(name)}
        end

      _invalid ->
        {:error, "This download link has expired. Try again."}
    end
  end

  defp check_name(name),
    do: if(Store.valid_name?(name), do: :ok, else: {:error, "no such backup"})

  ## Restoring

  @doc """
  Starts restoring the backup `name` as `admin`, who confirmed with the
  site's title: `:ok`, `{:error, :busy}` or `{:error, message}`.
  `:database` restores into another database than the repo's (tests).
  """
  def restore(name, %User{} = admin, confirmation, opts \\ []) do
    cond do
      not Store.valid_name?(name) ->
        {:error, "no such backup"}

      String.trim(confirmation || "") != SiteSettings.get("title") ->
        {:error, "Type the site's title exactly to confirm."}

      true ->
        Runner.run(:restore, fn log -> do_restore(name, admin, opts, log) end)
    end
  end

  defp do_restore(name, admin, opts, log) do
    before = read_only()
    log.("Turning on read-only mode")
    set_read_only("Restoring a backup")

    try do
      with {:ok, path, temporary?} <- Store.fetch(name),
           _ = log.("Unpacking #{name}"),
           {:ok, dir, meta} <- extract(path, temporary?),
           result = restore_from(dir, meta, opts, log),
           _ = File.rm_rf(dir),
           :ok <- result do
        reload(log)

        log_action(Accounts.get_user(admin.id), "backup.restore", %{
          name: name,
          by: admin.username
        })

        :ok
      end
    after
      log.(
        if before, do: "Leaving read-only mode on, as before", else: "Turning off read-only mode"
      )

      set_read_only(before && before.reason)
    end
  end

  defp extract(path, temporary?) do
    result = Archive.extract(path)
    if temporary?, do: File.rm(path)
    result
  end

  defp restore_from(dir, meta, opts, log) do
    log.("Restoring the database (backup of #{meta["title"]}, version #{meta["version"]})")

    with :ok <- Archive.pg_restore(Path.join(dir, "database.dump"), opts) do
      restore_uploads(Path.join(dir, "uploads"), log)
      migrate(opts, log)
    end
  end

  defp restore_uploads(source, log) do
    cond do
      not File.dir?(source) ->
        :ok

      local_uploads?() ->
        log.("Restoring the uploads")
        File.cp_r!(source, Storage.Local.root())

      true ->
        log.("Skipping the backup's uploads: uploads are stored in S3 now")
    end
  end

  # The backup may predate migrations of the code running now.
  defp migrate(opts, log) do
    Archive.with_repo(opts, fn pid ->
      case Ecto.Migrator.run(Repo, :up, all: true, dynamic_repo: pid, log: false) do
        [] -> log.("The database is up to date")
        versions -> log.("Ran #{length(versions)} migrations the backup predates")
      end
    end)

    :ok
  end

  # The database changed under every node's caches.
  defp reload(log) do
    log.("Reloading settings and plugins")
    SiteSettings.reload()
    Plugins.reload()
  end

  defp log_action(%User{} = admin, action, details),
    do: StaffLog.record(admin, action, {"backup", nil}, details)

  defp log_action(_nobody, action, details),
    do: StaffLog.record_system(action, {"backup", nil}, details)
end
