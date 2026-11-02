defmodule FirestormWeb.UploadsTest do
  use FirestormWeb.Web.ConnCase

  import FirestormWeb.UploadHelpers

  alias FirestormWeb.{AccountDeletion, AccountExport, Drafts, Forums, Messages, Repo}
  alias FirestormWeb.{SiteSettings, StaffLog, Uploads}
  alias FirestormWeb.Forums.StaffAction
  alias FirestormWeb.Uploads.{Processor, Storage, Upload}

  @moduletag :tmp_dir

  setup do
    {:ok, admin: admin_fixture(), user: user_fixture()}
  end

  defp set(settings, admin), do: {:ok, _} = SiteSettings.update(settings, admin)

  defp stored?(key), do: File.exists?(Path.join(Storage.Local.root(), key))

  # A JPEG taken sideways (EXIF orientation 6) with a GPS position.
  defp photo(dir) do
    image = Image.new!(60, 20, color: :red)

    {:ok, image} =
      Vix.Vips.Image.mutate(image, fn mutable ->
        :ok = Vix.Vips.MutableImage.set(mutable, "orientation", :gint, 6)

        :ok =
          Vix.Vips.MutableImage.set(
            mutable,
            "exif-ifd3-GPSLatitude",
            :gchararray,
            "52/1 30/1 0/1"
          )

        :ok = Vix.Vips.MutableImage.set(mutable, "exif-ifd3-GPSLatitudeRef", :gchararray, "N")
      end)

    path = Path.join(dir, "photo.jpg")
    Image.write!(image, path)
    path
  end

  describe "processing" do
    test "detects the type from the content, refusing active content" do
      assert Processor.detect(File.read!(image_file(System.tmp_dir!(), "a.png")), "x.jpg") ==
               {:ok, "image/png"}

      assert Processor.detect("%PDF-1.7 ...", "doc.txt") == {:ok, "application/pdf"}
      assert Processor.detect("just text", "notes.txt") == {:ok, "text/plain"}

      for {data, name} <- [
            {"<html><script>alert(1)</script>", "page.html"},
            {"<svg onload=alert(1)>", "image.svg"},
            {"<script>alert(1)</script>", "fake.png"},
            {"just text", "notes.html"},
            {<<0, 1, 2>>, "binary.txt"}
          ] do
        assert {:error, _} = Processor.detect(data, name)
      end
    end

    test "turns photos upright and strips EXIF, including GPS", %{user: user, tmp_dir: dir} do
      raw = File.read!(photo(dir))
      assert raw =~ "Exif"

      {:ok, upload} = Uploads.create(user, photo(dir), "photo.jpg")
      assert {upload.width, upload.height} == {20, 60}

      stored = File.read!(Path.join(Storage.Local.root(), Uploads.key(upload)))
      refute stored =~ "Exif"
      refute stored =~ "GPS"
      assert {:error, _no_exif} = stored |> Image.from_binary!() |> Image.exif()
    end

    test "scales big images down and makes a thumbnail", %{user: user, admin: admin, tmp_dir: dir} do
      set(%{"max_image_dimension" => "1000"}, admin)

      {:ok, upload} = Uploads.create(user, image_file(dir, "big.png", 2000, 500), "big.png")
      assert {upload.width, upload.height} == {1000, 250}
      assert upload.thumbnail
      assert stored?(Uploads.thumbnail_key(upload))

      thumbnail = Image.open!(Path.join(Storage.Local.root(), Uploads.thumbnail_key(upload)))
      assert Image.width(thumbnail) == Processor.thumbnail_size()

      assert Uploads.markdown(upload) ==
               "[![big.png](#{Uploads.thumbnail_url(upload)})](#{Uploads.url(upload)})"

      {:ok, small} = Uploads.create(user, image_file(dir, "small.png"), "small.png")
      refute small.thumbnail
      assert Uploads.markdown(small) == "![small.png](#{Uploads.url(small)})"
    end

    test "refuses images that don't decode", %{user: user, tmp_dir: dir} do
      path = file(dir, "broken.png", <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "garbage">>)
      assert {:error, "That image couldn't be read."} = Uploads.create(user, path, "broken.png")
    end

    test "stores other files as they are, linked rather than shown", %{user: user, tmp_dir: dir} do
      {:ok, upload} = Uploads.create(user, file(dir, "notes.txt", "hello"), "../notes <1>.txt")
      assert upload.filename == "notes__1_.txt"
      assert upload.content_type == "text/plain"
      assert Uploads.markdown(upload) == "[notes__1_.txt](#{Uploads.url(upload)})"
    end
  end

  describe "limits and dedupe" do
    test "refuses files over the size setting", %{user: user, admin: admin, tmp_dir: dir} do
      set(%{"max_upload_kb" => "1"}, admin)
      path = file(dir, "big.txt", String.duplicate("a", 2000))

      assert {:error, "That file is too large (1 KB max)."} =
               Uploads.create(user, path, "big.txt")
    end

    test "the same file is stored once", %{user: user, tmp_dir: dir} do
      path = image_file(dir, "a.png")
      {:ok, first} = Uploads.create(user, path, "a.png")
      # Unused yet: the same upload again.
      assert {:ok, ^first} = Uploads.create(user, path, "again.png")

      other = user_fixture()
      {:ok, theirs} = Uploads.create(other, path, "b.png")
      assert theirs.id != first.id
      assert Uploads.key(theirs) == Uploads.key(first)
      assert Repo.aggregate(Upload, :count) == 2
    end

    test "enforces the quota, counting each file once", %{user: user, admin: admin, tmp_dir: dir} do
      set(%{"upload_quota_mb" => "1", "max_upload_kb" => "2048"}, admin)
      half = String.duplicate("a", 600 * 1024)

      {:ok, first} = Uploads.create(user, file(dir, "a.txt", half), "a.txt")
      Uploads.attach("[a](#{Uploads.url(first)})", user, post_fixture(user))
      # Attached, so a new row; the same file costs nothing more.
      assert {:ok, _} = Uploads.create(user, file(dir, "a.txt", half), "a.txt")
      assert Uploads.quota_used(user) == 600 * 1024

      assert {:error, "You've used your upload space" <> _} =
               Uploads.create(user, file(dir, "b.txt", half <> "b"), "b.txt")

      set(%{"upload_quota_mb" => "0"}, admin)
      assert {:ok, _} = Uploads.create(user, file(dir, "b.txt", half <> "b"), "b.txt")
    end
  end

  defp post_fixture(user, category \\ nil) do
    thread = thread_fixture(category || category_fixture(), user)
    hd(Repo.preload(thread, :posts).posts)
  end

  describe "attaching and access" do
    test "a post attaches the uploads it links", %{user: user, tmp_dir: dir} do
      {:ok, upload} = Uploads.create(user, image_file(dir, "a.png"), "a.png")
      thread = thread_fixture(category_fixture(), user, %{body: Uploads.markdown(upload)})
      [post] = Repo.preload(thread, :posts).posts

      upload = Repo.reload!(upload)
      assert upload.attached_to == "post"
      assert upload.post_id == post.id
    end

    test "only the uploader's unused uploads are attached", %{user: user, tmp_dir: dir} do
      {:ok, upload} = Uploads.create(user, image_file(dir, "a.png"), "a.png")
      other = user_fixture()
      thread = thread_fixture(category_fixture(), other)
      {:ok, _} = Forums.create_post(thread, other, %{body: Uploads.markdown(upload)})
      assert Repo.reload!(upload).attached_to == nil

      post = post_fixture(user)
      {:ok, _} = Forums.update_post(post, user, %{body: "now with " <> Uploads.markdown(upload)})
      assert Repo.reload!(upload).post_id == post.id
    end

    test "uploads follow their post's visibility", %{user: user, admin: admin, tmp_dir: dir} do
      {:ok, upload} = Uploads.create(user, image_file(dir, "a.png"), "a.png")
      reader = user_fixture()

      # Unused: the uploader and admins only.
      assert Uploads.readable?(upload, user)
      assert Uploads.readable?(upload, admin)
      refute Uploads.readable?(upload, reader)
      refute Uploads.readable?(upload, nil)

      post = post_fixture(user)
      :ok = Uploads.attach(Uploads.markdown(upload), user, post)
      upload = Repo.reload!(upload)
      assert Uploads.readable?(upload, nil)
      assert Uploads.readable?(upload, reader)

      # Hidden after flags: its author and admins only.
      Repo.update!(Ecto.Changeset.change(post, hidden_at: DateTime.utc_now(:second)))
      refute Uploads.readable?(upload, reader)
      assert Uploads.readable?(upload, user)

      # Deleted: admins only.
      Repo.update!(
        Ecto.Changeset.change(Repo.reload!(post),
          hidden_at: nil,
          deleted_at: DateTime.utc_now(:second)
        )
      )

      refute Uploads.readable?(upload, user)
      assert Uploads.readable?(upload, admin)
    end

    test "uploads in a private category are for its readers", %{user: user, tmp_dir: dir} do
      admin = admin_fixture()
      {:ok, team} = FirestormWeb.Groups.create_group(%{name: "insiders"}, admin)
      {:ok, _} = FirestormWeb.Groups.add_member(team, user.username, admin)
      {:ok, category} = Forums.create_category(%{title: "Secret", role_ids: [team.id]})

      {:ok, upload} = Uploads.create(user, image_file(dir, "a.png"), "a.png")
      thread_fixture(category, user, %{body: Uploads.markdown(upload)})
      upload = Repo.reload!(upload)

      assert Uploads.readable?(upload, user)
      refute Uploads.readable?(upload, user_fixture())
      refute Uploads.readable?(upload, nil)
    end

    test "uploads in private messages are for its participants", %{user: user, tmp_dir: dir} do
      {:ok, upload} = Uploads.create(user, image_file(dir, "a.png"), "a.png")
      recipient = user_fixture()

      {:ok, _conversation} =
        Messages.start_conversation(user, %{
          "title" => "Hi",
          "recipients" => recipient.username,
          "body" => Uploads.markdown(upload)
        })

      upload = Repo.reload!(upload)
      assert upload.attached_to == "message"
      assert Uploads.readable?(upload, recipient)
      refute Uploads.readable?(upload, user_fixture())
      refute Uploads.readable?(upload, nil)
    end
  end

  describe "removal" do
    test "unused uploads go after the grace period, unless a draft uses them", %{
      user: user,
      tmp_dir: dir
    } do
      {:ok, orphan} = Uploads.create(user, image_file(dir, "a.png", 50, 50), "a.png")
      {:ok, drafted} = Uploads.create(user, image_file(dir, "b.png", 51, 51), "b.png")
      {:ok, used} = Uploads.create(user, image_file(dir, "c.png", 52, 52), "c.png")
      :ok = Uploads.attach(Uploads.markdown(used), user, post_fixture(user))
      thread = thread_fixture(category_fixture(), user_fixture())
      {:ok, _} = Drafts.save(user, {:reply, thread}, %{body: Uploads.markdown(drafted)})

      assert Uploads.run_due() == 0
      later = DateTime.add(DateTime.utc_now(), 25, :hour)
      assert Uploads.run_due(later) == 1

      refute Repo.reload(orphan)
      refute stored?(Uploads.key(orphan))
      assert Repo.reload(drafted)
      assert Repo.reload(used)
    end

    test "a stored file shared by another upload stays", %{user: user, tmp_dir: dir} do
      path = image_file(dir, "a.png")
      {:ok, mine} = Uploads.create(user, path, "a.png")
      {:ok, theirs} = Uploads.create(user_fixture(), path, "a.png")

      :ok =
        Uploads.attach(
          Uploads.markdown(theirs),
          Repo.preload(theirs, :user).user,
          post_fixture(user)
        )

      assert Uploads.run_due(DateTime.add(DateTime.utc_now(), 25, :hour)) == 1
      refute Repo.reload(mine)
      assert stored?(Uploads.key(theirs))
    end

    test "admins delete uploads, which the staff log records", %{
      user: user,
      admin: admin,
      tmp_dir: dir
    } do
      {:ok, upload} = Uploads.create(user, image_file(dir, "a.png"), "a.png")
      assert :ok = Uploads.delete(upload, admin)

      refute Repo.reload(upload)
      refute stored?(Uploads.key(upload))

      assert [%StaffAction{action: "upload.delete", target_type: "upload"} = entry] =
               Repo.all(StaffAction)

      assert entry.details["filename"] == "a.png"
      assert entry.details["uploader"] == user.username
      assert "upload.delete" in StaffLog.actions()
    end
  end

  describe "avatars" do
    test "are cropped square, public and replace the previous one", %{user: user, tmp_dir: dir} do
      {:ok, user} = Uploads.set_avatar(user, image_file(dir, "me.png", 600, 300), "me.png")
      first = Repo.get!(Upload, user.avatar_upload_id)
      assert {first.width, first.height} == {256, 256}
      assert first.attached_to == "avatar"
      assert Uploads.readable?(first, nil)
      assert FirestormWeb.Forums.User.avatar_url(user) == "/avatars/#{first.id}"

      {:ok, user} = Uploads.set_avatar(user, image_file(dir, "me2.png", 300, 600), "me2.png")
      refute Repo.reload(first)
      assert user.avatar_upload_id

      {:ok, user} = Uploads.remove_avatar(user)
      refute user.avatar_upload_id
      assert Repo.aggregate(Upload, :count) == 0
    end

    test "must be images", %{user: user, tmp_dir: dir} do
      assert {:error, "An avatar must be an image."} =
               Uploads.set_avatar(user, file(dir, "a.txt", "text"), "a.txt")
    end
  end

  describe "account data" do
    test "exports uploads, and deletion removes the unused ones and the avatar", %{
      user: user,
      tmp_dir: dir
    } do
      {:ok, unused} = Uploads.create(user, image_file(dir, "a.png", 40, 40), "a.png")
      {:ok, used} = Uploads.create(user, image_file(dir, "b.png", 41, 41), "b.png")
      :ok = Uploads.attach(Uploads.markdown(used), user, post_fixture(user))
      {:ok, user} = Uploads.set_avatar(user, image_file(dir, "me.png"), "me.png")

      export = AccountExport.build(user)
      assert length(export.uploads) == 3

      assert Enum.any?(
               export.uploads,
               &(&1.url == Uploads.url(used) and &1.attached_to == "post")
             )

      user = Forums.get_user!(user.id)
      {:ok, deleted} = AccountDeletion.delete_account(user, user.username)
      refute deleted.avatar_upload_id

      refute Repo.reload(unused)
      assert Repo.reload(used)
      assert Repo.aggregate(Upload, :count) == 1
    end
  end

  describe "serving" do
    test "images inline, other files as downloads, never sniffed", %{
      conn: conn,
      user: user,
      tmp_dir: dir
    } do
      {:ok, image} = Uploads.create(user, image_file(dir, "a.png"), "a.png")
      {:ok, pdf} = Uploads.create(user, file(dir, "doc.pdf", "%PDF-1.4 fake"), "doc.pdf")
      post = post_fixture(user)
      :ok = Uploads.attach("#{Uploads.markdown(image)} #{Uploads.markdown(pdf)}", user, post)

      response = get(conn, Uploads.url(image))
      assert response.status == 200
      assert get_resp_header(response, "content-type") == ["image/png"]
      assert get_resp_header(response, "content-disposition") == [~s(inline; filename="a.png")]
      assert get_resp_header(response, "x-content-type-options") == ["nosniff"]

      response = get(conn, Uploads.url(pdf))
      assert response.status == 200
      assert get_resp_header(response, "content-type") == ["application/pdf"]

      assert get_resp_header(response, "content-disposition") == [
               ~s(attachment; filename="doc.pdf")
             ]

      assert get_resp_header(response, "content-security-policy") == [
               "default-src 'none'; sandbox"
             ]
    end

    test "is a 404 for those who may not see it", %{conn: conn, user: user, tmp_dir: dir} do
      {:ok, upload} = Uploads.create(user, image_file(dir, "a.png"), "a.png")

      assert get(conn, Uploads.url(upload)).status == 404
      assert get(log_in_as(conn, user_fixture()), Uploads.url(upload)).status == 404
      assert get(log_in_as(conn, user), Uploads.url(upload)).status == 200
      assert get(conn, "/uploads/#{String.duplicate("x", 22)}/a.png").status == 404
    end

    test "thumbnails and avatars", %{conn: conn, user: user, tmp_dir: dir} do
      {:ok, upload} = Uploads.create(user, image_file(dir, "big.png", 1500, 1000), "big.png")
      :ok = Uploads.attach(Uploads.markdown(upload), user, post_fixture(user))
      response = get(conn, Uploads.thumbnail_url(upload))
      assert response.status == 200
      assert response.resp_body |> Image.from_binary!() |> Image.width() == 640

      {:ok, user} = Uploads.set_avatar(user, image_file(dir, "me.png"), "me.png")
      assert get(conn, "/avatars/#{user.avatar_upload_id}").status == 200
      assert get(conn, "/avatars/#{upload.id}").status == 404
      assert get(conn, "/avatars/nope").status == 404
    end
  end

  describe "API" do
    test "uploads a file", %{conn: conn, user: user, tmp_dir: dir} do
      path = image_file(dir, "a.png")

      response =
        conn
        |> put_req_header("authorization", "Bearer #{user.api_token}")
        |> post("/api/v1/uploads",
          file: %Plug.Upload{path: path, filename: "a.png", content_type: "image/png"}
        )
        |> json_response(201)

      assert response["data"]["url"] =~ ~r"\A/uploads/[A-Za-z0-9_-]{22}/a\.png\z"
      assert response["data"]["markdown"] == "![a.png](#{response["data"]["url"]})"
    end

    test "refuses what isn't allowed, and visitors", %{conn: conn, user: user, tmp_dir: dir} do
      path = file(dir, "page.html", "<script>alert(1)</script>")
      file = %Plug.Upload{path: path, filename: "page.html", content_type: "text/html"}

      assert conn |> post("/api/v1/uploads", file: file) |> json_response(401)

      assert conn
             |> put_req_header("authorization", "Bearer #{user.api_token}")
             |> post("/api/v1/uploads", file: file)
             |> json_response(422) == %{"error" => "That file type isn't allowed."}
    end
  end
end
