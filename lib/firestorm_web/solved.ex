defmodule FirestormWeb.Solved do
  @moduledoc """
  Accepted answers, for Q&A: in a category that allows them
  (`Category.allow_accepted_answers`), the thread's author or staff mark
  one reply as the answer (the `:accept_answer` policy), and can unmark it
  or pick another. The thread then counts as solved: its page shows the
  answer under the first post, lists show a "Solved" badge, and search has
  `status:solved` / `status:unsolved` (see `FirestormWeb.Search`).

  Only a published reply qualifies: not the first post, nor a deleted,
  hidden or queued one. An accepted answer that stops qualifying is
  unaccepted (`clear/1`): when it's deleted (`Forums.delete_post/2`), hidden
  after flags or by staff review, or moved to another thread by a merge or
  split (see `FirestormWeb.TopicTools`).

  The answer's author is told (`answer_accepted`), and staff accepting or
  unaccepting on someone else's thread goes to the staff log. A thread
  author under a penalty can't (see `FirestormWeb.Posting.check/2`).
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Posting, Repo, StaffLog}
  alias FirestormWeb.Forums.{Policy, Post, Thread, User}
  alias FirestormWeb.Web.Paths

  @doc """
  Accepts `post` as `thread`'s answer, as `actor`. Returns `{:ok, thread}`,
  or `{:error, reason}` (see `message/1`, and `Posting.message/1` for
  penalties).
  """
  def accept(%Thread{} = thread, %Post{} = post, %User{} = actor) do
    result =
      Repo.transact(fn ->
        thread = Thread |> lock("FOR UPDATE") |> Repo.get!(thread.id)
        post = Repo.get!(Post, post.id)

        with :ok <- authorize(actor, thread),
             :ok <- acceptable(thread, post) do
          updated = thread |> Ecto.Changeset.change(accepted_post_id: post.id) |> Repo.update!()
          log(actor, "thread.accept_answer", updated, post)
          {:ok, updated}
        end
      end)

    with {:ok, updated} <- result do
      notify_author(updated, post, actor)
      Forums.thread_changed(:thread_updated, updated)
      {:ok, updated}
    end
  end

  @doc "Unaccepts `thread`'s answer, as `actor`. Returns `{:ok, thread}` or `{:error, reason}`."
  def unaccept(%Thread{} = thread, %User{} = actor) do
    result =
      Repo.transact(fn ->
        thread = Thread |> lock("FOR UPDATE") |> Repo.get!(thread.id)

        with :ok <- authorize(actor, thread),
             %Post{} = post <-
               (thread.accepted_post_id && Repo.get(Post, thread.accepted_post_id)) ||
                 {:error, :not_solved} do
          updated = thread |> Ecto.Changeset.change(accepted_post_id: nil) |> Repo.update!()
          log(actor, "thread.unaccept_answer", updated, post)
          {:ok, updated}
        end
      end)

    with {:ok, updated} <- result do
      Forums.thread_changed(:thread_updated, updated)
      {:ok, updated}
    end
  end

  # Penalties bind authors and staff alike (staff can't be penalized).
  defp authorize(actor, thread) do
    if Bodyguard.permit?(Forums, :accept_answer, actor, thread),
      do: Posting.check(actor, :like),
      else: {:error, :unauthorized}
  end

  @doc """
  Whether `post` may be accepted as the answer in its thread, whose first
  post is `first_post`: a published reply anyone may read.
  """
  def acceptable?(%Post{} = post, %Post{} = first_post),
    do: post.id != first_post.id and Post.readable_by?(post, nil)

  defp acceptable(thread, post) do
    cond do
      post.thread_id != thread.id -> {:error, :not_acceptable}
      Forums.first_post?(post) -> {:error, :first_post}
      not Post.readable_by?(post, nil) -> {:error, :not_acceptable}
      true -> :ok
    end
  end

  # Staff on someone else's thread.
  defp log(actor, action, thread, post) do
    if Forums.thread_author_id(thread) != actor.id do
      post = Repo.preload(post, :user)

      StaffLog.record(actor, action, thread, %{
        title: thread.title,
        post_id: post.id,
        author: post.user && post.user.username,
        excerpt: String.slice(post.body, 0, 200)
      })
    end
  end

  defp notify_author(thread, post, actor) do
    author = Repo.get(User, post.user_id)

    if (author && author.id != actor.id) and not User.deleted?(author) and
         Policy.thread_readers(thread, [author]) != [] do
      Forums.notify(author, %{
        kind: "answer_accepted",
        subject: "Your reply was accepted as the answer in \"#{thread.title}\"",
        body: post.body,
        url: "#{Paths.thread_url(thread)}#post-#{post.id}",
        thread_id: thread.id,
        post_id: post.id
      })
    end
  end

  @doc """
  Unaccepts any thread's answer among the posts with `post_ids` (they're
  deleted, hidden or moving away). Runs inside the caller's transaction;
  the caller tells pages, as it does about the posts.
  """
  def clear(post_ids) do
    post_ids = List.wrap(post_ids)

    Repo.update_all(where(Thread, [t], t.accepted_post_id in ^post_ids),
      set: [accepted_post_id: nil]
    )

    :ok
  end

  def message(:unauthorized), do: "You can't accept answers in this thread."
  def message(:first_post), do: "The first post can't be its own thread's answer."
  def message(:not_acceptable), do: "That post can't be accepted as the answer."
  def message(:not_solved), do: "This thread has no accepted answer."
  def message(reason), do: Posting.message(reason)
end
