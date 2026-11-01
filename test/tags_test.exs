defmodule FirestormWeb.TagsTest do
  use FirestormWeb.DataCase

  alias FirestormWeb.{Forums, Notifications, Repo}
  alias FirestormWeb.Forums.{Subscriptions, Tag}

  setup do
    {:ok, category} = Forums.create_category(%{title: "Elixir"})
    %{category: category, author: user("author"), reader: user("reader")}
  end

  defp user(name) do
    {:ok, user} = Forums.create_user(%{username: name, name: name, email: "#{name}@example.com"})
    user
  end

  defp thread(category, author, tags, title \\ "OTP") do
    {:ok, thread} =
      Forums.create_thread(category, author, %{title: title, body: "Hi", tags: tags})

    thread
  end

  defp tag_names(thread),
    do: thread |> Repo.preload(:tags, force: true) |> Map.get(:tags) |> Enum.map(& &1.name)

  defp listed?(threads, thread), do: Enum.any?(threads, &(&1.id == thread.id))

  test "parse/1 splits, downcases and dedupes" do
    assert Tag.parse(" OTP, beam  #Phoenix,otp ") == ["otp", "beam", "phoenix"]
    assert Tag.parse(nil) == []
  end

  test "threads get tags on creation and edit, creating new tags", %{
    category: category,
    author: author
  } do
    thread = thread(category, author, "otp, Beam")
    assert tag_names(thread) == ["beam", "otp"]

    {:ok, thread} = Forums.update_thread(thread, %{"tags" => "otp genserver"}, author)
    assert tag_names(thread) == ["genserver", "otp"]

    # Editing other fields leaves the tags alone
    {:ok, thread} = Forums.update_thread(thread, %{"title" => "Renamed"}, author)
    assert tag_names(thread) == ["genserver", "otp"]
  end

  test "ensure_tags/1 takes tags created concurrently as they are" do
    [existing] = Forums.ensure_tags(["otp"])
    assert [^existing, %Tag{name: "beam"}] = Forums.ensure_tags(["otp", "beam"])
    assert Repo.aggregate(Tag, :count) == 2
  end

  test "at most 5 valid tags", %{category: category, author: author} do
    assert {:error, changeset} =
             Forums.create_thread(category, author, %{title: "T", body: "B", tags: "a b c d e f"})

    assert "can have at most 5 tags" in errors_on(changeset).tags

    for bad <- ["no_underscores", "-dash", String.duplicate("x", 31)] do
      assert {:error, changeset} =
               Forums.create_thread(category, author, %{title: "T", body: "B", tags: bad})

      assert [message] = errors_on(changeset).tags
      assert message =~ "use lowercase letters, digits and dashes"
    end
  end

  test "with FIREFLY_TAGS_ADMIN_ONLY, only admins create tags", %{
    category: category,
    author: author
  } do
    Application.put_env(:firestorm_web, :tags_admin_only, true)
    on_exit(fn -> Application.delete_env(:firestorm_web, :tags_admin_only) end)

    assert {:error, changeset} =
             Forums.create_thread(category, author, %{title: "T", body: "B", tags: "brand-new"})

    assert ["brand-new: no such tag"] = errors_on(changeset).tags

    admin = user("admin")
    {:ok, role} = Forums.create_role("admin")
    {:ok, _} = Forums.add_role(admin, role)
    thread(category, admin, "brand-new", "By admin")
    assert tag_names(thread(category, author, "brand-new", "Reused")) == ["brand-new"]
  end

  test "tag lists count and list listed threads only", %{category: category, author: author} do
    one = thread(category, author, "otp", "One")
    two = thread(category, author, "otp beam", "Two")
    archived = thread(category, author, "otp", "Old")
    {:ok, _} = Forums.archive_thread(archived, true)

    assert [%{name: "otp", threads_count: 2}, %{name: "beam", threads_count: 1}] =
             Forums.list_tags()

    threads = Forums.tag_threads(Forums.get_tag!("OTP"), nil)
    assert Enum.map(threads, & &1.id) |> Enum.sort() == Enum.sort([one.id, two.id])
    assert [%Tag{} | _] = hd(threads).tags
  end

  describe "tag levels" do
    setup %{category: category, author: author} do
      %{thread: thread(category, author, "otp")}
    end

    test "watching a tag notifies of its new threads and posts in any category", ctx do
      %{category: category, author: author, reader: reader, thread: thread} = ctx
      {:ok, _} = Notifications.start_link()
      {:ok, _} = Subscriptions.set_tag_level(reader, Forums.get_tag!("otp"), "watching")

      thread(category, author, "otp", "Another")
      {:ok, _} = Forums.create_post(thread, author, %{body: "more"})
      :sys.get_state(Notifications)

      assert [%{kind: "new_post"}, %{kind: "new_thread"}] = Forums.notifications_for(reader)
      assert Subscriptions.effective_thread_level(reader, thread) == "watching"
    end

    test "a muted tag hides its threads, even in a watched category", ctx do
      %{category: category, reader: reader, thread: thread} = ctx
      {:ok, _} = Subscriptions.set_category_level(reader, category, "watching")
      {:ok, _} = Subscriptions.set_tag_level(reader, Forums.get_tag!("otp"), "muted")

      assert Subscriptions.effective_thread_level(reader, thread) == "muted"
      refute listed?(Forums.latest_threads(reader), thread)

      refute Enum.any?(Subscriptions.subscribers(thread), fn {user, _} -> user.id == reader.id end)

      # The thread-level choice wins
      {:ok, _} = Subscriptions.set_thread_level(reader, thread, "tracking")
      assert Subscriptions.effective_thread_level(reader, thread) == "tracking"
      assert Subscriptions.inherited_level(reader, thread) == "muted"
      assert listed?(Forums.latest_threads(reader), thread)
    end

    test "the most attentive of category and tag levels applies", ctx do
      %{category: category, reader: reader, thread: thread} = ctx
      {:ok, _} = Subscriptions.set_category_level(reader, category, "normal")
      {:ok, _} = Subscriptions.set_tag_level(reader, Forums.get_tag!("otp"), "tracking")

      assert Subscriptions.effective_thread_level(reader, thread) == "tracking"

      assert [{%{id: id}, "tracking"}] =
               Subscriptions.subscribers(thread)
               |> Enum.filter(fn {u, _} -> u.id == reader.id end)

      assert id == reader.id
    end
  end
end
