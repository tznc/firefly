defmodule Firefly.UploadsPropertyTest do
  @moduledoc """
  Properties of `Firefly.Uploads`: stored filenames are always safe (and
  cleaning is idempotent); storing any bytes under any name is accepted or
  refused, never a crash, and what's stored renders safely; the quota
  counts each distinct file once; and who may fetch an attachment is
  exactly who may read the thread it's in.
  """
  # Sync: it makes admins (the shared admin role) and writes files.
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.{Discussion, Groups, HTMLSafety, Uploads}
  alias Firefly.Rendering.Markdown

  defp write_tmp(data) do
    path = Path.join(System.tmp_dir!(), "upload-prop-#{System.unique_integer([:positive])}")
    File.write!(path, data)
    path
  end

  property "safe_filename/1 keeps only safe characters, is never a dot name, and is idempotent" do
    check all(
            name <-
              one_of([
                any_text(),
                adversarial_text(),
                member_of(["..", ".", "", "../../etc/passwd", "a/b\\\\c"])
              ]),
            max_runs: runs(300)
          ) do
      safe = Uploads.safe_filename(name)
      assert safe =~ ~r/\A[A-Za-z0-9._-]{1,100}\z/
      refute safe in [".", ".."]
      assert Uploads.safe_filename(safe) == safe
    end
  end

  test "storing any bytes under any name is accepted or refused, and renders safely" do
    check all(
            data <-
              one_of([
                binary(min_length: 1, max_length: 300),
                map(adversarial_text(), &(&1 <> "x"))
              ]),
            name <-
              one_of([
                adversarial_text(4),
                member_of(["notes.txt", "a.png", "x.svg", "../evil.txt", "<b>.txt"])
              ]),
            max_runs: runs(40)
          ) do
      user = user_fixture()
      path = write_tmp(data)

      case Uploads.create(user, path, name) do
        {:ok, upload} ->
          assert upload.filename == Uploads.safe_filename(name)
          html = Markdown.render(Uploads.markdown(upload))
          assert HTMLSafety.unsafe(html) == [], html

        {:error, reason} ->
          assert is_binary(reason) or is_atom(reason)
      end

      File.rm(path)
    end
  end

  test "the quota counts each distinct file once" do
    check all(
            contents <-
              list_of(member_of(["alpha", "beta", "gamma"]), min_length: 1, max_length: 5),
            max_runs: runs(20)
          ) do
      user = user_fixture()

      for content <- contents do
        path = write_tmp(content)
        {:ok, _} = Uploads.create(user, path, "note.txt")
        File.rm(path)
      end

      expected = contents |> Enum.uniq() |> Enum.map(&byte_size/1) |> Enum.sum()
      assert Uploads.quota_used(user) == expected
    end
  end

  test "an attachment may be fetched exactly by who may read its thread" do
    admin = admin_fixture()
    {:ok, team} = Groups.create_group(%{name: "team#{System.unique_integer([:positive])}"}, admin)

    check all(restricted? <- boolean(), insider? <- boolean(), max_runs: runs(12)) do
      author = user_fixture()
      reader = user_fixture()
      if insider?, do: {:ok, _} = Groups.add_member(team, reader.username, admin)
      {:ok, _} = Groups.add_member(team, author.username, admin)

      attrs = %{title: "Cat #{System.unique_integer([:positive])}"}
      attrs = if restricted?, do: Map.put(attrs, :role_ids, [team.id]), else: attrs
      {:ok, category} = Discussion.create_category(attrs)

      path = write_tmp("attached notes")
      {:ok, upload} = Uploads.create(author, path, "notes.txt")
      File.rm(path)

      # Unattached: the uploader's (and staff's) only.
      assert Uploads.readable?(upload, author)
      refute Uploads.readable?(upload, reader)

      {:ok, thread} =
        Discussion.create_thread(category, author, %{
          title: "With a file",
          body: "See #{Uploads.markdown(upload)}"
        })

      upload = Uploads.get_by_token(upload.token)

      for viewer <- [nil, reader, author, admin] do
        assert Uploads.readable?(upload, viewer) ==
                 Bodyguard.permit?(Discussion, :view_thread, viewer, thread),
               "restricted: #{restricted?}, insider: #{insider?}, viewer: #{inspect(viewer && viewer.username)}"
      end
    end
  end
end
