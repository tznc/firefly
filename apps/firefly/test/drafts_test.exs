defmodule Firefly.DraftsTest do
  use Firefly.DataCase

  import Firefly.Fixtures,
    only: [user_fixture: 0, admin_fixture: 0, category_fixture: 1, thread_fixture: 3]

  alias Firefly.{Discussion, Groups}
  alias Firefly.Accounts.{AccountDeletion, AccountExport}
  alias Firefly.Discussion.Drafts
  alias Firefly.Moderation.TopicTools
  alias Firefly.Discussion.{Draft, Post}

  setup do
    user = user_fixture()
    category = category_fixture("Elixir")
    thread = thread_fixture(category, user, %{title: "T", body: "op"})
    %{user: user, category: category, thread: thread}
  end

  test "one draft per context, saved over, private", %{
    user: user,
    category: category,
    thread: thread
  } do
    other = user_fixture()

    {:ok, _} = Drafts.save(user, {:reply, thread}, %{body: "first"})
    {:ok, _} = Drafts.save(user, {:reply, thread}, %{"body" => "second"})
    {:ok, _} = Drafts.save(user, {:new_thread, category}, %{title: "Idea", tags: "otp", body: ""})

    assert %Draft{body: "second", kind: "reply"} = Drafts.get(user, {:reply, thread})
    assert %Draft{title: "Idea", tags: "otp"} = Drafts.get(user, {:new_thread, category})
    assert Drafts.get(other, {:reply, thread}) == nil
    assert Drafts.list(other) == []
    assert Repo.aggregate(Draft, :count) == 2

    # Someone else can't delete it by id.
    draft = Drafts.get(user, {:reply, thread})
    :ok = Drafts.delete(other, draft.id)
    assert Drafts.get(user, {:reply, thread})
    :ok = Drafts.delete(user, draft.id)
    refute Drafts.get(user, {:reply, thread})
  end

  test "a blank draft is dropped", %{user: user, thread: thread} do
    {:ok, _} = Drafts.save(user, {:reply, thread}, %{body: "words"})
    assert {:ok, nil} = Drafts.save(user, {:reply, thread}, %{body: "  "})
    refute Drafts.get(user, {:reply, thread})
  end

  test "capped in size like a post, and in number", %{
    user: user,
    category: category,
    thread: thread
  } do
    too_long = String.duplicate("a", Post.max_body_length() + 1)
    assert {:error, changeset} = Drafts.save(user, {:reply, thread}, %{body: too_long})
    assert errors_on(changeset).body != []

    assert {:error, changeset} =
             Discussion.create_post(thread, user, %{body: too_long})

    assert errors_on(changeset).body != []

    {:ok, _} = Drafts.save(user, {:new_thread, category}, %{title: "kept"})
    now = NaiveDateTime.utc_now()

    Repo.insert_all(
      Draft,
      for n <- 2..Drafts.max_drafts() do
        %{
          user_id: user.id,
          key: "reply:test-#{n}",
          kind: "reply",
          thread_id: thread.id,
          body: "b",
          inserted_at: now,
          updated_at: now
        }
      end
    )

    assert {:error, :too_many} = Drafts.save(user, {:reply, thread}, %{body: "one too many"})
    # Saving over one of them is fine.
    assert {:ok, _} = Drafts.save(user, {:new_thread, category}, %{title: "again"})
  end

  test "the list leaves out what the user can no longer resume", %{
    user: user,
    category: category,
    thread: thread
  } do
    {:ok, reply} = Discussion.create_post(thread, user, %{body: "reply"})
    {:ok, _} = Drafts.save(user, {:reply, thread}, %{body: "r"})
    {:ok, _} = Drafts.save(user, {:new_thread, category}, %{title: "n"})
    {:ok, _} = Drafts.save(user, {:edit, reply}, %{body: "e"})
    assert length(Drafts.list(user)) == 3

    {:ok, _} = Discussion.delete_post(reply, user)
    assert Enum.map(Drafts.list(user), & &1.kind) |> Enum.sort() == ["new_thread", "reply"]

    # The category is restricted to a group the user isn't in.
    admin = admin_fixture()
    {:ok, role} = Groups.create_role("staff-only")
    {:ok, _} = Discussion.update_category(category, %{"role_ids" => [role.id]}, admin)
    assert Drafts.list(user) == []
  end

  test "drafts go with their thread; merges carry reply drafts", %{
    user: user,
    category: category,
    thread: thread
  } do
    admin = admin_fixture()
    target = thread_fixture(category, user, %{title: "Target", body: "x"})
    {:ok, _} = Drafts.save(user, {:reply, thread}, %{body: "r"})

    {:ok, _} = TopicTools.merge(thread, target, admin)
    assert %Draft{body: "r"} = Drafts.get(user, {:reply, target})

    {:ok, _} = Discussion.delete_thread(Repo.get!(Firefly.Discussion.Thread, target.id), admin)
    assert Repo.aggregate(Draft, :count) == 0
  end

  test "exported, and deleted with the account", %{user: user, thread: thread} do
    {:ok, _} = Drafts.save(user, {:reply, thread}, %{body: "secret plans"})

    assert [%{kind: "reply", body: "secret plans", thread_id: thread_id}] =
             AccountExport.build(user).drafts

    assert thread_id == thread.id

    {:ok, _} = AccountDeletion.delete_account(user, user.username)
    assert Repo.aggregate(Draft, :count) == 0
  end

  test "a title or tags too long in code points is refused, not a crash", %{
    user: user,
    category: category
  } do
    # 100 graphemes but 300 code points, past the varchar(255) column.
    zalgo = String.duplicate("e\u0301\u0308", 100)

    for field <- [:title, :tags] do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Drafts.save(user, {:new_thread, category}, %{field => zalgo})

      assert changeset.errors[field]
    end
  end
end
