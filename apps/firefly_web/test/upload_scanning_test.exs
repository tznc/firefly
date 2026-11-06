defmodule FireflyWeb.UploadScanningTest do
  # Configures the scanner globally.
  use FireflyWeb.ConnCase, async: false

  import Firefly.UploadHelpers

  alias Firefly.{Repo, Uploads}
  alias Firefly.Moderation.StaffAction
  alias Firefly.Uploads.{ScanWorker, Scanner, Upload}

  @moduletag :tmp_dir

  # A clamd that answers each INSTREAM with `reply` (after reading the
  # whole stream), and sends the scanned bytes to the test.
  defp fake_clamd(reply) do
    test = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    pid =
      spawn_link(fn ->
        Stream.repeatedly(fn -> :ok end)
        |> Enum.each(fn _ ->
          {:ok, socket} = :gen_tcp.accept(listen)
          {:ok, "zINSTREAM\0"} = :gen_tcp.recv(socket, 10)
          send(test, {:scanned, read_stream(socket, "")})
          :ok = :gen_tcp.send(socket, "stream: " <> reply <> "\0")
          :gen_tcp.close(socket)
        end)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp read_stream(socket, acc) do
    {:ok, <<size::32>>} = :gen_tcp.recv(socket, 4)

    if size == 0 do
      acc
    else
      {:ok, chunk} = :gen_tcp.recv(socket, size)
      read_stream(socket, acc <> chunk)
    end
  end

  defp scan_with(port) do
    Application.put_env(:firefly, Scanner, host: "127.0.0.1", port: port, timeout: 5_000)
    on_exit(fn -> Application.delete_env(:firefly, Scanner) end)
  end

  defp run_scan(upload),
    do: perform_job(ScanWorker, %{upload_id: upload.id, sha256: upload.sha256})

  setup do
    {:ok, user: user_fixture(), admin: admin_fixture()}
  end

  test "scanning is off unless configured", %{user: user, tmp_dir: dir} do
    refute Scanner.enabled?()
    {:ok, upload} = Uploads.create(user, file(dir, "a.txt", "hello"), "a.txt")
    assert upload.scan_status == "clean"
    refute_enqueued(worker: ScanWorker)
  end

  test "talks clamd's INSTREAM protocol, in chunks" do
    data = :crypto.strong_rand_bytes(150_000)
    scan_with(fake_clamd("OK"))
    assert Scanner.scan(data) == :clean
    assert_received {:scanned, ^data}

    scan_with(fake_clamd("Win.Test.EICAR_HDB-1 FOUND"))
    assert Scanner.scan("X5O!P%@AP") == {:infected, "Win.Test.EICAR_HDB-1"}

    scan_with(fake_clamd("INSTREAM size limit exceeded. ERROR"))
    assert {:error, {:clamd, _}} = Scanner.scan("data")
  end

  test "a clamd that can't be reached is an error, so the job retries" do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    scan_with(port)

    assert {:error, :econnrefused} = Scanner.scan("data")
  end

  test "a new upload isn't served until it's scanned clean", %{
    conn: conn,
    user: user,
    tmp_dir: dir
  } do
    scan_with(fake_clamd("OK"))
    {:ok, upload} = Uploads.create(user, file(dir, "notes.txt", "hello"), "notes.txt")
    assert upload.scan_status == "pending"
    assert_enqueued(worker: ScanWorker, args: %{upload_id: upload.id})

    conn = log_in_as(conn, user)
    assert get(conn, Uploads.url(upload)).status == 404

    assert :ok = run_scan(upload)
    assert_received {:scanned, "hello"}
    assert Repo.reload(upload).scan_status == "clean"
    assert get(conn, Uploads.url(upload)).status == 200

    # The same file again is already known clean.
    {:ok, again} = Uploads.create(user_fixture(), file(dir, "n.txt", "hello"), "n.txt")
    assert again.scan_status == "clean"
  end

  test "an infected upload is quarantined, logged and refused from then on", %{
    conn: conn,
    user: user,
    admin: admin,
    tmp_dir: dir
  } do
    scan_with(fake_clamd("Eicar-Signature FOUND"))
    path = file(dir, "eicar.txt", "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR")
    {:ok, upload} = Uploads.create(user, path, "eicar.txt")

    assert :ok = run_scan(upload)
    assert Repo.reload(upload).scan_status == "quarantined"
    refute Uploads.readable?(Repo.reload(upload), admin)
    assert get(log_in_as(conn, admin), Uploads.url(upload)).status == 404

    assert %StaffAction{actor_id: nil, details: details} =
             Repo.get_by(StaffAction, action: "upload.quarantine", target_id: upload.id)

    assert details["signature"] == "Eicar-Signature"
    assert details["uploader"] == user.username

    assert {:error, "That file was refused by the virus scanner."} =
             Uploads.create(user_fixture(), path, "eicar.txt")

    # Staff see it on the uploads page.
    admin_conn = log_in_as(build_conn(), admin)

    admin_conn
    |> visit(~p"/staff/uploads")
    |> assert_has("#upload-#{upload.id}", text: "Quarantined")
  end

  test "a failed scan leaves the upload unserved for a retry", %{user: user, tmp_dir: dir} do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    scan_with(port)

    {:ok, upload} = Uploads.create(user, file(dir, "a.txt", "hi"), "a.txt")
    assert {:error, :econnrefused} = run_scan(upload)
    assert %Upload{scan_status: "pending"} = Repo.reload(upload)
  end
end
