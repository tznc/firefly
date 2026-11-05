defmodule Firefly.TagsTest do
  use Firefly.DataCase
  # The notifications process delivers emails; route them to this test.
  import Swoosh.TestAssertions

  # Mail is sent from other processes (the notifications process, LiveViews).
  setup :set_swoosh_global

  alias Firefly.{Accounts, Discussion, Groups, Notifications, Repo}
  alias Firefly.Discussion.Tag
  alias Firefly.Notifications.Subscriptions

  setup do
    {:ok, category} = Discussion.create_category(%{title: "Elixir"})
    %{category: category, author: user("author"), reader: user("reader")}
  end

  defp user(name) do
    {:ok, user} =
      Accounts.create_user(%{username: name, name: name, email: "#{name}@example.com"})

    user
  end

  defp thread(category, author, tags, title \\ "OTP") do
    {:ok, thread} =
      Discussion.create_thread(category, author, %{title: title, body: "Hi", tags: tags})

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

    {:ok, thread} = Discussion.update_thread(thread, %{"tags" => "otp genserver"}, author)
    assert tag_names(thread) == ["genserver", "otp"]

    # Editing other fields leaves the tags alone
    {:ok, thread} = Discussion.update_thread(thread, %{"title" => "Renamed"}, author)
    assert tag_names(thread) == ["genserver", "otp"]
  end

  test "ensure_tags/1 takes tags created concurrently as they are" do
    [existing] = Discussion.ensure_tags(["otp"])
    assert [^existing, %Tag{name: "beam"}] = Discussion.ensure_tags(["otp", "beam"])
    assert Repo.aggregate(Tag, :count) == 2
  end

  test "at most 5 valid tags", %{category: category, author: author} do
    assert {:error, changeset} =
             Discussion.create_thread(category, author, %{
               title: "T",
               body: "B",
               tags: "a b c d e f"
             })

    assert "can have at most 5 tags" in errors_on(changeset).tags

    for bad <- ["no_underscores", "-dash", String.duplicate("x", 31)] do
      assert {:error, changeset} =
               Discussion.create_thread(category, author, %{title: "T", body: "B", tags: bad})

      assert [message] = errors_on(changeset).tags
      assert message =~ "use lowercase letters, digits and dashes"
    end
  end

  test "with FIREFLY_TAGS_ADMIN_ONLY, only admins create tags", %{
    category: category,
    author: author
  } do
    System.put_env("FIREFLY_TAGS_ADMIN_ONLY", "true")
    on_exit(fn -> System.delete_env("FIREFLY_TAGS_ADMIN_ONLY") end)

    assert {:error, changeset} =
             Discussion.create_thread(category, author, %{
               title: "T",
               body: "B",
               tags: "brand-new"
             })

    assert ["brand-new: no such tag"] = errors_on(changeset).tags

    admin = user("admin")
    {:ok, role} = Groups.create_role("admin")
    {:ok, _} = Groups.add_role(admin, role)
    thread(category, admin, "brand-new", "By admin")
    assert tag_names(thread(category, author, "brand-new", "Reused")) == ["brand-new"]
  end

  test "tag lists count and list listed threads only", %{category: category, author: author} do
    one = thread(category, author, "otp", "One")
    two = thread(category, author, "otp beam", "Two")
    archived = thread(category, author, "otp", "Old")
    {:ok, _} = Discussion.archive_thread(archived, true, author)

    assert [%{name: "otp", threads_count: 2}, %{name: "beam", threads_count: 1}] =
             Discussion.list_tags()

    threads = Discussion.tag_threads(Discussion.get_tag!("OTP"), nil)
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
      {:ok, _} = Subscriptions.set_tag_level(reader, Discussion.get_tag!("otp"), "watching")

      thread(category, author, "otp", "Another")
      {:ok, _} = Discussion.create_post(thread, author, %{body: "more"})
      :sys.get_state(Notifications)

      assert [%{kind: "new_post"}, %{kind: "new_thread"}] =
               Notifications.notifications_for(reader)

      assert Subscriptions.effective_thread_level(reader, thread) == "watching"
    end

    test "a muted tag hides its threads, even in a watched category", ctx do
      %{category: category, reader: reader, thread: thread} = ctx
      {:ok, _} = Subscriptions.set_category_level(reader, category, "watching")
      {:ok, _} = Subscriptions.set_tag_level(reader, Discussion.get_tag!("otp"), "muted")

      assert Subscriptions.effective_thread_level(reader, thread) == "muted"
      refute listed?(Discussion.latest_threads(reader), thread)

      refute Enum.any?(Subscriptions.subscribers(thread), fn {user, _} -> user.id == reader.id end)

      # The thread-level choice wins
      {:ok, _} = Subscriptions.set_thread_level(reader, thread, "tracking")
      assert Subscriptions.effective_thread_level(reader, thread) == "tracking"
      assert Subscriptions.inherited_level(reader, thread) == "muted"
      assert listed?(Discussion.latest_threads(reader), thread)
    end

    test "the most attentive of category and tag levels applies", ctx do
      %{category: category, reader: reader, thread: thread} = ctx
      {:ok, _} = Subscriptions.set_category_level(reader, category, "normal")
      {:ok, _} = Subscriptions.set_tag_level(reader, Discussion.get_tag!("otp"), "tracking")

      assert Subscriptions.effective_thread_level(reader, thread) == "tracking"

      assert [{%{id: id}, "tracking"}] =
               Subscriptions.subscribers(thread)
               |> Enum.filter(fn {u, _} -> u.id == reader.id end)

      assert id == reader.id
    end
  end
end
