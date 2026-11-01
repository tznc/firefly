defmodule FirestormWeb.StaffLogTest do
  use FirestormWeb.DataCase

  import FirestormWeb.Web.ConnCase,
    only: [
      user_fixture: 1,
      admin_fixture: 0,
      category_fixture: 1,
      thread_fixture: 3
    ]

  alias FirestormWeb.{Forums, Repo, StaffLog}
  alias FirestormWeb.Forums.StaffAction

  setup do
    admin = admin_fixture()
    author = user_fixture(%{username: "author"})
    category = category_fixture("Elixir")
    thread = thread_fixture(category, author, %{title: "Supervisors"})
    {:ok, reply} = Forums.create_post(thread, author, %{body: "Restart them"})
    %{admin: admin, author: author, category: category, thread: thread, reply: reply}
  end

  defp log, do: StaffAction |> order_by(:id) |> Repo.all()

  defp actions, do: Enum.map(log(), & &1.action)

  test "thread moderation is logged with its actor", %{admin: admin, thread: thread} do
    {:ok, thread} = Forums.pin_thread(thread, true, admin)
    {:ok, thread} = Forums.pin_thread(thread, false, admin)
    {:ok, thread} = Forums.close_thread(thread, true, admin)
    {:ok, thread} = Forums.close_thread(thread, false, admin)
    {:ok, thread} = Forums.archive_thread(thread, true, admin)
    {:ok, _} = Forums.archive_thread(thread, false, admin)

    assert actions() ==
             ~w(thread.pin thread.unpin thread.close thread.open thread.archive thread.unarchive)

    assert %StaffAction{target_type: "thread", details: %{"title" => "Supervisors"}} = hd(log())
    assert Enum.all?(log(), &(&1.actor_id == admin.id and &1.target_id == thread.id))
  end

  test "moves record where from and to", %{admin: admin, thread: thread} do
    erlang = category_fixture("Erlang")
    {:ok, _} = Forums.move_thread(thread, erlang, admin)

    assert [%{action: "thread.move", details: details}] = log()

    assert details == %{
             "title" => "Supervisors",
             "from_category" => "Elixir",
             "to_category" => "Erlang"
           }
  end

  test "staff edits of others' posts and threads keep before and after", ctx do
    %{admin: admin, author: author, thread: thread, reply: reply} = ctx

    {:ok, _} = Forums.update_post(reply, author, %{body: "Own edit"})
    {:ok, _} = Forums.update_thread(thread, %{"title" => "Own rename"}, author)
    assert log() == []

    reply = Forums.get_post!(reply.id)
    {:ok, _} = Forums.update_post(reply, admin, %{body: "Moderated"})
    {:ok, _} = Forums.update_thread(Forums.get_thread!(thread.id), %{"title" => "Renamed"}, admin)

    assert [post_edit, thread_edit] = log()
    assert post_edit.action == "post.edit"
    assert post_edit.details["body"] == %{"before" => "Own edit", "after" => "Moderated"}
    assert post_edit.details["author"] == "author"
    assert thread_edit.details["title"] == %{"before" => "Own rename", "after" => "Renamed"}
  end

  test "staff deletes and restores are logged; authors deleting their own aren't", ctx do
    %{admin: admin, author: author, thread: thread, reply: reply} = ctx
    {:ok, own} = Forums.create_post(thread, author, %{body: "Oops"})
    {:ok, _} = Forums.delete_post(own, author)
    assert log() == []

    {:ok, deleted} = Forums.delete_post(reply, admin)
    {:ok, _} = Forums.restore_post(deleted, admin)
    {:ok, _} = Forums.delete_thread(thread, admin)

    assert actions() == ~w(post.delete post.restore thread.delete)
    assert hd(log()).details["excerpt"] == "Restart them"
    assert List.last(log()).details == %{"title" => "Supervisors", "category" => "Elixir"}

    own_thread = thread_fixture(ctx.category, author, %{title: "Mine"})
    {:ok, _} = Forums.delete_thread(own_thread, author)
    assert length(log()) == 3
  end

  test "category changes are logged with an actor, not by seeds", %{admin: admin} do
    {:ok, category} = Forums.create_category(%{title: "Phoenix"}, admin)
    {:ok, category} = Forums.update_category(category, %{title: "Phoenix LiveView"}, admin)
    {:ok, _} = Forums.delete_category(category, admin)
    {:ok, _} = Forums.create_category(%{title: "Seeded"})

    assert [created, updated, deleted] = log()
    assert created.action == "category.create"
    assert updated.details["title"] == %{"before" => "Phoenix", "after" => "Phoenix LiveView"}
    assert deleted.details == %{"title" => "Phoenix LiveView"}
  end

  test "a failed action logs nothing", %{admin: admin, category: category} do
    assert {:error, _} = Forums.update_category(category, %{title: ""}, admin)
    assert log() == []
  end

  test "list/2 filters by action and actor; targets/1 finds what still exists", ctx do
    %{admin: admin, thread: thread, reply: reply} = ctx
    other = admin_fixture()
    {:ok, _} = Forums.pin_thread(thread, true, admin)
    {:ok, _} = Forums.delete_post(reply, other)

    assert [%{action: "post.delete"}, %{action: "thread.pin"}] = StaffLog.list(%{}, 1).entries
    assert [%{action: "thread.pin"}] = StaffLog.list(%{"action" => "thread.pin"}, 1).entries
    assert [%{actor_id: id}] = StaffLog.list(%{"actor" => other.id}, 1).entries
    assert id == other.id
    assert Enum.map(StaffLog.actors(), & &1.id) |> Enum.sort() == Enum.sort([admin.id, other.id])

    assert %{thread: %{title: "Supervisors"}} =
             StaffLog.targets(StaffLog.list(%{}, 1).entries)[{"post", reply.id}]

    {:ok, _} = Forums.delete_thread(thread, admin)
    assert StaffLog.targets(StaffLog.list(%{}, 1).entries) == %{}
  end
end
