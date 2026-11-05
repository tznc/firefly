defmodule Firefly.BackupsTest do
  # Backups run in their own process, read-only mode is global, and each
  # test makes (and drops) a scratch database: never the test database.
  use Firefly.DataCase, async: false

  import Firefly.Fixtures

  alias Firefly.{Backups, Repo, SiteSettings}
  alias Firefly.Backups.{Archive, Store}
  alias Firefly.Moderation.{Posting, StaffAction}

  setup do
    File.rm_rf!(Store.dir())
    database = "firefly_backup_test_#{System.unique_integer([:positive])}"
    admin_query!("CREATE DATABASE #{database}")

    on_exit(fn ->
      Backups.set_read_only(nil)
      admin_query!("DROP DATABASE IF EXISTS #{database} WITH (FORCE)")
    end)

    {:ok, database: database}
  end

  # A connection outside the sandbox, for what can't run in a transaction.
  defp admin_query!(sql) do
    config = Repo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port] || 5432,
        username: config[:username],
        password: config[:password],
        database: "postgres"
      )

    Postgrex.query!(conn, sql, [])
    GenServer.stop(conn)
  end

  # Runs `sql` in the scratch database.
  defp scratch!(database, sql) do
    Archive.with_repo([database: database], fn _pid -> Repo.query!(sql) end)
  end

  defp wait_for(operation) do
    receive do
      {:backup_finished, ^operation, result} -> result
    after
      60_000 -> flunk("#{operation} didn't finish")
    end
  end

  test "a dump restores over the database, in a scratch database", %{database: database} do
    scratch!(database, "CREATE TABLE notes (body text)")
    scratch!(database, "INSERT INTO notes VALUES ('kept')")

    path = Path.join(System.tmp_dir!(), "#{database}.tar.gz")
    on_exit(fn -> File.rm(path) end)
    assert :ok = Archive.build(path, %{title: "Scratch"}, database: database)

    scratch!(database, "UPDATE notes SET body = 'changed'")
    scratch!(database, "CREATE TABLE later (id int)")

    assert {:ok, dir, %{"title" => "Scratch", "format" => 1, "migration" => nil}} =
             Archive.extract(path)

    assert :ok = Archive.pg_restore(Path.join(dir, "database.dump"), database: database)
    File.rm_rf!(dir)

    assert %{rows: [["kept"]]} = scratch!(database, "SELECT body FROM notes")
    # Not in the backup, so left alone.
    assert %{rows: [[0]]} = scratch!(database, "SELECT count(*) FROM later")
  end

  test "backup and restore round trip, with the migrations the backup predates",
       %{database: database} do
    admin = admin_fixture()
    Backups.subscribe()

    scratch!(database, "CREATE TABLE notes (body text)")
    scratch!(database, "INSERT INTO notes VALUES ('before')")

    assert :ok = Backups.create(admin, database: database, uploads: false)
    assert {:ok, name} = wait_for(:backup)
    assert [%{name: ^name, size: size}] = Backups.list()
    assert size > 0
    assert Repo.get_by(StaffAction, action: "backup.create").details == %{"name" => name}

    scratch!(database, "DROP TABLE notes")

    assert {:error, "Type the site's title exactly to confirm."} =
             Backups.restore(name, admin, "nope", database: database)

    assert :ok = Backups.restore(name, admin, SiteSettings.get("title"), database: database)
    assert_receive {:backup_log, "Turning on read-only mode"}, 5_000
    assert :ok = wait_for(:restore)

    assert %{rows: [["before"]]} = scratch!(database, "SELECT body FROM notes")
    # The backup was of a database without Firefly's tables: migrations ran.
    assert %{rows: [[count]]} = scratch!(database, "SELECT count(*) FROM schema_migrations")
    assert count > 50
    assert_received {:backup_log, "Ran " <> _}

    refute Backups.read_only?()
    assert Repo.get_by(StaffAction, action: "backup.restore")
    assert %{running: nil, log: log} = Backups.status()
    assert "Done." in log
  end

  test "only one runs at a time", %{database: database} do
    Backups.subscribe()
    assert :ok = Backups.create(nil, database: database, uploads: false)
    assert {:error, :busy} = Backups.create(nil, database: database, uploads: false)
    assert {:ok, _name} = wait_for(:backup)
  end

  test "uploads stored locally go in the backup" do
    root = Firefly.Uploads.Storage.Local.root()
    File.mkdir_p!(Path.join(root, "original"))
    File.write!(Path.join(root, "original/backup-test.txt"), "hello")
    on_exit(fn -> File.rm(Path.join(root, "original/backup-test.txt")) end)

    path = Path.join(System.tmp_dir!(), "uploads-#{System.unique_integer([:positive])}.tar.gz")
    on_exit(fn -> File.rm(path) end)
    assert :ok = Archive.build(path, %{}, uploads_dir: root)

    assert {:ok, dir, _meta} = Archive.extract(path)
    assert File.read!(Path.join(dir, "uploads/original/backup-test.txt")) == "hello"
    File.rm_rf!(dir)
  end

  test "downloads are signed for the admin who asked, and logged" do
    admin = admin_fixture()
    File.mkdir_p!(Store.dir())
    File.write!(Path.join(Store.dir(), "site-2026-01-01-000000.tar.gz"), "x")

    token = Backups.download_token("site-2026-01-01-000000.tar.gz", admin)
    assert {:ok, "site-2026-01-01-000000.tar.gz", {:file, path}} = Backups.download(token, admin)
    assert File.read!(path) == "x"
    assert Repo.get_by(StaffAction, action: "backup.download")

    assert {:error, _} = Backups.download(token, admin_fixture())
    assert {:error, _} = Backups.download("forged", admin)

    traversal = Backups.download_token("../../etc/passwd", admin)
    assert {:error, "no such backup"} = Backups.download(traversal, admin)

    assert :ok = Backups.delete("site-2026-01-01-000000.tar.gz", admin)
    assert Backups.list() == []
  end

  test "scheduled backups keep the newest ones", %{database: database} do
    admin = admin_fixture()

    {:ok, _} =
      SiteSettings.update(%{"backup_frequency_days" => "1", "backup_keep" => "2"}, admin)

    File.mkdir_p!(Store.dir())

    for day <- ~w(01 02 03),
        do: File.write!(Path.join(Store.dir(), "firefly-2020-01-#{day}-000000.tar.gz"), "x")

    Backups.subscribe()
    # Scheduled backups are of the repo's database; this one is pointed at
    # the scratch one by making it by hand, as run_due would.
    assert :ok = Backups.create(nil, database: database, uploads: false)
    assert {:ok, name} = wait_for(:backup)

    assert Enum.map(Backups.list(), & &1.name) == [name, "firefly-2020-01-03-000000.tar.gz"]
    assert Repo.get_by(StaffAction, action: "backup.create").actor_id == nil
  end

  test "read-only mode stops posting" do
    user = user_fixture()
    thread = thread_fixture(category_fixture(), user)

    Backups.set_read_only("Maintenance", admin_fixture())
    assert %{reason: "Maintenance"} = Backups.read_only()
    assert {:error, :read_only} = Posting.check(user, thread)
    assert {:error, :read_only} = Posting.check(user, :like)
    assert Posting.message(:read_only) =~ "read-only"
    assert Repo.get_by(StaffAction, action: "backup.read_only").details == %{"on" => true}

    Backups.set_read_only(nil)
    assert :ok = Posting.check(user, thread)
  end
end
