defmodule FirestormWeb.Web.UploadsLiveTest do
  use FirestormWeb.Web.ConnCase

  import FirestormWeb.UploadHelpers

  alias FirestormWeb.{Repo, Uploads}
  alias FirestormWeb.Uploads.Upload

  @moduletag :tmp_dir

  test "admins list and delete uploads", %{conn: conn, tmp_dir: dir} do
    admin = admin_fixture()
    user = user_fixture(%{username: "uploader"})
    {:ok, upload} = Uploads.create(user, image_file(dir, "cat.png"), "cat.png")

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/uploads")
    |> assert_has("#upload-#{upload.id}", text: "cat.png")
    |> assert_has("#upload-#{upload.id}", text: "uploader")
    |> assert_has("#upload-#{upload.id}", text: "Unused")
    |> click_button("#upload-#{upload.id} button", "Delete")
    |> assert_has("#flash-info", text: "Deleted cat.png.")
    |> assert_has("#uploads-empty")

    refute Repo.get(Upload, upload.id)
  end

  test "members can't see the uploads page", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/uploads")
    |> assert_path(~p"/")
  end

  test "members upload and remove an avatar", %{conn: conn, tmp_dir: dir} do
    user = user_fixture()

    session =
      conn
      |> log_in_as(user)
      |> visit(~p"/settings/profile")
      |> upload("Avatar picture", image_file(dir, "me.png", 300, 200))
      |> assert_has("#flash-info", text: "Avatar updated.")

    user = Repo.reload!(user)
    assert user.avatar_upload_id
    assert_has(session, ~s{#avatar-form img[src="/avatars/#{user.avatar_upload_id}"]})

    session
    |> click_button("Remove")
    |> assert_has("#flash-info", text: "Avatar removed.")

    refute Repo.reload!(user).avatar_upload_id
  end
end
