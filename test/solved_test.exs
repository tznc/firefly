defmodule FirestormWeb.SolvedTest do
  use FirestormWeb.DataCase

  import FirestormWeb.Web.ConnCase,
    only: [user_fixture: 0, admin_fixture: 0, category_fixture: 1, thread_fixture: 3]

  alias FirestormWeb.{Flags, Forums, Penalties, Review, Search, Solved, TopicTools}
  alias FirestormWeb.Forums.{Notification, Post, StaffAction, Thread}

  setup do
    admin = admin_fixture()
    asker = user_fixture()
    helper = user_fixture()
    {:ok, qa} = Forums.create_category(%{title: "Q&A", allow_accepted_answers: true})
    thread = thread_fixture(qa, asker, %{title: "How do I?", body: "the question"})
    {:ok, answer} = Forums.create_post(thread, helper, %{body: "like this"})
    {:ok, other} = Forums.create_post(thread, admin, %{body: "or like that"})

    %{
      admin: admin,
      asker: asker,
      helper: helper,
      qa: qa,
      thread: thread,
      answer: answer,
      other: other
    }
  end

  defp first_post(thread),
    do:
      Repo.one(
        from(p in Post, where: p.thread_id == ^thread.id, order_by: [:inserted_at, :id], limit: 1)
      )

  defp log_entries(action), do: Repo.all(from(a in StaffAction, where: a.action == ^action))

  defp accepted_id(thread), do: Repo.reload!(thread).accepted_post_id

  defp kinds(user),
    do: Repo.all(from(n in Notification, where: n.user_id == ^user.id, select: n.kind))

  test "the thread's author accepts a reply; its author is told", %{
    asker: asker,
    helper: helper,
    thread: thread,
    answer: answer,
    other: other
  } do
    assert {:ok, %Thread{accepted_post_id: id}} = Solved.accept(thread, answer, asker)
    assert id == answer.id
    assert "answer_accepted" in kinds(helper)
    # Not staff action.
    assert log_entries("thread.accept_answer") == []

    # Another one replaces it; then none.
    {:ok, _} = Solved.accept(thread, other, asker)
    assert accepted_id(thread) == other.id
    {:ok, _} = Solved.unaccept(thread, asker)
    assert accepted_id(thread) == nil
    assert {:error, :not_solved} = Solved.unaccept(thread, asker)
  end

  test "only the author and staff, only on replies, only where allowed", %{
    admin: admin,
    asker: asker,
    helper: helper,
    thread: thread,
    answer: answer
  } do
    assert {:error, :unauthorized} = Solved.accept(thread, answer, helper)
    assert {:error, :first_post} = Solved.accept(thread, first_post(thread), asker)

    elsewhere = thread_fixture(category_fixture("Chat"), asker, %{title: "Chat", body: "hi"})
    {:ok, reply} = Forums.create_post(elsewhere, helper, %{body: "hello"})
    assert {:error, :unauthorized} = Solved.accept(elsewhere, reply, asker)
    assert {:error, :unauthorized} = Solved.accept(elsewhere, reply, admin)

    # A post from another thread.
    assert {:error, :not_acceptable} = Solved.accept(thread, reply, asker)

    # Archived: staff only.
    {:ok, archived} = Forums.archive_thread(thread, true, admin)
    assert {:error, :unauthorized} = Solved.accept(archived, answer, asker)
    assert {:ok, _} = Solved.accept(archived, answer, admin)
  end

  test "staff on someone else's thread is logged", %{
    admin: admin,
    thread: thread,
    answer: answer
  } do
    {:ok, _} = Solved.accept(thread, answer, admin)

    assert [%{target_id: id, details: %{"post_id" => post_id}}] =
             log_entries("thread.accept_answer")

    assert {id, post_id} == {thread.id, answer.id}

    {:ok, _} = Solved.unaccept(thread, admin)
    assert [_] = log_entries("thread.unaccept_answer")
  end

  test "a silenced author can't", %{admin: admin, asker: asker, thread: thread, answer: answer} do
    {:ok, _} =
      Penalties.penalize(:silence, asker, admin, %{"duration" => "1d", "reason" => "calm down"})

    assert {:error, {:silenced, _}} = Solved.accept(thread, answer, asker)
  end

  test "deleted, hidden or queued posts aren't (or stop being) the answer", %{
    admin: admin,
    asker: asker,
    helper: helper,
    thread: thread,
    answer: answer,
    other: other
  } do
    {:ok, _} = Solved.accept(thread, answer, asker)
    {:ok, _} = Forums.delete_post(answer, helper)
    assert accepted_id(thread) == nil
    assert {:error, :not_acceptable} = Solved.accept(thread, Repo.reload!(answer), asker)

    # Hidden after flags.
    {:ok, _} = Solved.accept(thread, other, asker)
    {:ok, flagged} = Forums.create_post(thread, helper, %{body: "spam"})
    {:ok, _} = Solved.accept(thread, flagged, asker)

    for _ <- 1..3,
        do: {:ok, _} = Flags.flag_post(flagged, user_fixture(), %{"reason" => "spam"})

    assert Post.hidden?(Repo.reload!(flagged))
    assert accepted_id(thread) == nil

    # Hidden by staff review.
    {:ok, _} = Solved.accept(thread, other, asker)
    {:ok, _} = Flags.flag_post(Repo.reload!(other), helper, %{"reason" => "spam"})
    {:ok, _} = Review.agree(Repo.reload!(other) |> Repo.preload([:thread, :user]), admin, :hide)
    assert accepted_id(thread) == nil

    queued =
      Repo.insert!(%Post{
        thread_id: thread.id,
        user_id: helper.id,
        body: "pending",
        queued_at: DateTime.utc_now(:second)
      })

    assert {:error, :not_acceptable} = Solved.accept(thread, queued, asker)
  end

  test "a split moving the answer away unaccepts it", %{
    admin: admin,
    asker: asker,
    qa: qa,
    thread: thread,
    answer: answer
  } do
    {:ok, _} = Solved.accept(thread, answer, asker)

    {:ok, split} =
      TopicTools.split(
        thread,
        [answer.id],
        {:new, %{"title" => "Own thread", "category_id" => qa.id}},
        admin
      )

    assert accepted_id(thread) == nil
    assert accepted_id(split) == nil
  end

  test "a merge unaccepts the source's answer and keeps the target's", %{
    admin: admin,
    asker: asker,
    helper: helper,
    qa: qa,
    thread: thread,
    answer: answer
  } do
    {:ok, _} = Solved.accept(thread, answer, asker)
    target = thread_fixture(qa, helper, %{title: "Same question", body: "q"})
    {:ok, target_answer} = Forums.create_post(target, asker, %{body: "answer"})
    {:ok, _} = Solved.accept(target, target_answer, helper)

    {:ok, _} = TopicTools.merge(thread, target, admin)
    assert accepted_id(thread) == nil
    assert accepted_id(target) == target_answer.id
  end

  test "search by status", %{asker: asker, qa: qa, thread: thread, answer: answer} do
    open = thread_fixture(qa, asker, %{title: "Still open", body: "unanswered question"})

    chat =
      thread_fixture(category_fixture("Chat"), asker, %{title: "Chat", body: "just chatting"})

    {:ok, _} = Solved.accept(thread, answer, asker)

    thread_ids = fn query ->
      query
      |> Search.parse()
      |> Search.run(asker)
      |> Map.get(:entries)
      |> Enum.map(& &1.thread.id)
      |> Enum.uniq()
    end

    assert thread_ids.("status:solved") == [thread.id]
    assert thread_ids.("status:unsolved") == [open.id]
    assert thread_ids.("chatting status:unsolved") == []
    assert chat.id in thread_ids.("chatting")
  end
end
