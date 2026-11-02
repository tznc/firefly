defmodule FirestormWeb.EmojiTest do
  use FirestormWeb.Web.ConnCase, async: false

  import FirestormWeb.DataCase, only: [errors_on: 1]
  import FirestormWeb.UploadHelpers

  alias FirestormWeb.{Emoji, Markdown, Repo, Uploads}
  alias FirestormWeb.Emoji.CustomEmoji
  alias FirestormWeb.Forums.StaffAction
  alias FirestormWeb.Uploads.Upload

  @moduletag :tmp_dir

  setup do
    # The cache is global; each test's emoji are rolled back with it.
    on_exit(fn -> Emoji.put_cache(%{}) end)
    {:ok, admin: admin_fixture()}
  end

  defp add(admin, name, dir, size \\ 300) do
    Emoji.create(
      admin,
      %{"name" => name},
      image_file(dir, "#{name}.png", size, size),
      "#{name}.png"
    )
  end

  describe "custom emoji" do
    test "are scaled down, public and logged", %{admin: admin, tmp_dir: dir} do
      {:ok, emoji} = add(admin, "partyblob", dir)
      upload = Repo.get!(Upload, emoji.upload_id)

      assert upload.attached_to == "emoji"
      assert {upload.width, upload.height} == {128, 128}
      assert Uploads.readable?(upload, nil)
      assert Emoji.custom() == %{"partyblob" => Uploads.url(upload)}

      assert [%StaffAction{action: "emoji.create", details: %{"name" => "partyblob"}}] =
               Repo.all(StaffAction)

      assert [%{name: "partyblob"}] = FirestormWeb.AccountExport.build(admin).custom_emoji_added
    end

    test "need a valid, free, non-standard name and an image", %{admin: admin, tmp_dir: dir} do
      assert {:error, changeset} = add(admin, "a", dir)

      assert errors_on(changeset).name == [
               "use 2 to 32 lowercase letters, digits and underscores"
             ]

      assert {:error, changeset} = add(admin, "x\"><script>", dir)
      assert errors_on(changeset).name != []

      assert {:error, changeset} = add(admin, "smile", dir)
      assert errors_on(changeset).name == ["is already a standard emoji"]

      {:ok, _} = add(admin, "partyblob", dir)
      assert {:error, changeset} = add(admin, "Partyblob", dir, 200)
      assert errors_on(changeset).name == ["is already taken"]
      # The refused emoji's image isn't kept.
      assert Repo.aggregate(Upload, :count) == 1

      path = file(dir, "a.txt", "text")

      assert {:error, "An emoji must be an image."} =
               Emoji.create(admin, %{"name" => "texty"}, path, "a.txt")
    end

    test "removing one removes its image and logs it", %{admin: admin, tmp_dir: dir} do
      {:ok, emoji} = add(admin, "partyblob", dir)
      assert :ok = Emoji.delete(emoji, admin)

      assert Emoji.custom() == %{}
      refute Repo.get(Upload, emoji.upload_id)
      assert Repo.get_by(StaffAction, action: "emoji.delete")
    end

    test "deleting the image from the uploads page removes the emoji", %{
      admin: admin,
      tmp_dir: dir
    } do
      {:ok, emoji} = add(admin, "partyblob", dir)
      :ok = Uploads.delete(Repo.get!(Upload, emoji.upload_id), admin)

      refute Repo.get(CustomEmoji, emoji.id)
      assert Emoji.custom() == %{}
    end
  end

  describe "rendering" do
    test ":name: becomes a sanitized emoji image, but not in code", %{admin: admin, tmp_dir: dir} do
      {:ok, emoji} = add(admin, "partyblob", dir)
      url = Uploads.url(Repo.preload(emoji, :upload).upload)

      html = Markdown.render("Party :partyblob: time :fire: `:partyblob:`\n\n    :partyblob:")

      assert html =~
               ~s(<img src="#{url}" alt=":partyblob:" title=":partyblob:" class="emoji">) or
               html =~ ~s(<img class="emoji" src="#{url}" alt=":partyblob:" title=":partyblob:">)

      assert html =~ "🔥"
      assert html =~ "<code>:partyblob:</code>"
      assert html =~ "<pre class=\"line-numbers\"><code>:partyblob:\n</code></pre>"
      assert Markdown.render(":unknown_one:") == "<p>:unknown_one:</p>"
    end

    test "the emoji class can't carry scripts or other classes" do
      html =
        Markdown.render(
          ~s{<img class="emoji evil" src="javascript:alert(1)" onerror="alert(1)">} <>
            ~s{<script>alert(1)</script><img class="other" src="/x.png">}
        )

      refute html =~ "evil"
      refute html =~ "javascript:"
      refute html =~ "onerror"
      refute html =~ "<script"
      refute html =~ "other"
      assert html =~ ~s(class="emoji")
    end

    test "plugin output is sanitized with the same allow-list" do
      assert FirestormWeb.Plugins.Content.sanitize(
               ~s(<img class="emoji" src="/e.png" onload="x">)
             ) ==
               ~s(<img class="emoji" src="/e.png">)
    end
  end

  describe "pages" do
    test "admins add and remove emoji", %{conn: conn, admin: admin, tmp_dir: dir} do
      session =
        conn
        |> log_in_as(admin)
        |> visit(~p"/staff/emoji")
        |> assert_has("#emoji-empty")
        |> fill_in("Name", with: "partyblob")
        |> upload("Image", image_file(dir, "partyblob.png"))
        |> click_button("Add emoji")
        |> assert_has("#flash-info", text: "Added :partyblob:.")
        |> assert_has("#custom-emoji li", text: ":partyblob:")

      emoji = Repo.get_by!(CustomEmoji, name: "partyblob")

      session
      |> click_button("#emoji-#{emoji.id} button", "Remove")
      |> assert_has("#flash-info", text: "Removed :partyblob:.")
      |> assert_has("#emoji-empty")
    end

    test "members can't manage emoji", %{conn: conn} do
      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/staff/emoji")
      |> assert_path(~p"/")
    end

    test "the composer offers custom emoji to the picker", %{
      conn: conn,
      admin: admin,
      tmp_dir: dir
    } do
      {:ok, _} = add(admin, "partyblob", dir)
      thread = thread_fixture(category_fixture(), admin)

      conn
      |> log_in_as(admin)
      |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}/posts/new")
      |> assert_has("#post_body-emoji[data-custom-emoji*='partyblob']")
      |> assert_has("#post_body[data-custom-emoji*='partyblob']")
      |> fill_in("Body", with: "Hi :partyblob:")
      |> assert_has("#post-preview img.emoji[alt=':partyblob:']")
    end
  end
end
