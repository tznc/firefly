defmodule FirestormWeb.Review do
  @moduledoc """
  The staff review queue (`/staff/review`): posts with pending flags (see
  `FirestormWeb.Flags`), grouped per post, and posts awaiting approval (a
  new user's first `approve_new_user_posts` posts; see
  `FirestormWeb.Forums.approval_required?/1`).

  Flag decisions settle every pending flag on the post:

    * agree, and hide the post (it stays hidden), soft-delete it (a first
      post takes its thread with it) or also silence its author
      (`FirestormWeb.Penalties`)
    * disagree: the flags were wrong, the post is shown again
    * defer: ignore the flags, leaving the post as it is

  A queued post is approved (published then, so subscribers and mentioned
  users are notified at that moment, not before) or rejected with a reason
  the author is told. Every decision goes to the staff log in the same
  transaction, and open review pages (and staff's sidebar badge) update
  live through `changed/0`.
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Penalties, Repo, StaffLog}
  alias FirestormWeb.Forums.{Flag, Post, User}

  @topic "staff:review"

  @doc "Subscribes the caller to queue changes (`:review_changed`)."
  def subscribe, do: Phoenix.PubSub.subscribe(FirestormWeb.PubSub, @topic)

  @doc "Tells open review pages and staff badges that the queue changed."
  def changed, do: Phoenix.PubSub.broadcast(FirestormWeb.PubSub, @topic, :review_changed)

  @doc "How many items wait for review: flagged posts plus queued posts."
  def pending_count do
    flagged = from(f in Flag, where: f.status == "pending", select: count(f.post_id, :distinct))
    Repo.one(flagged) + Repo.aggregate(queued_query(), :count)
  end

  @doc """
  Posts with pending flags, longest-waiting first, each with its thread,
  author and pending flags (with who flagged).
  """
  def flagged_posts do
    pending =
      from(f in Flag, where: f.status == "pending", order_by: f.inserted_at, preload: :user)

    Post
    |> join(:inner, [p], f in Flag, on: f.post_id == p.id and f.status == "pending")
    |> group_by([p], p.id)
    |> order_by([p, f], asc: min(f.inserted_at))
    |> preload([:user, thread: :category, flags: ^pending])
    |> Repo.all()
  end

  @doc "Posts awaiting approval, oldest first, with their thread and author."
  def queued_posts do
    queued_query()
    |> order_by(asc: :queued_at, asc: :id)
    |> preload([:user, thread: :category])
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :first?, Forums.first_post?(&1)))
  end

  defp queued_query, do: where(Post, [p], not is_nil(p.queued_at) and is_nil(p.deleted_at))

  ## Flags

  @doc """
  Agrees with the post's flags as `admin`, then `decision`: `:hide`,
  `:delete` or `{:silence, params}` (the author, with
  `FirestormWeb.Penalties.penalize/4` params). Errors: `:no_pending_flags`,
  or a penalty error.
  """
  def agree(%Post{} = post, %User{} = admin, decision) do
    post = Repo.preload(post, [:thread, :user])

    decide(post, admin, "agreed", "flag.agree", %{decision: decision_name(decision)}, fn ->
      carry_out(decision, post, admin)
    end)
  end

  @doc "Disagrees with the post's flags as `admin`: it's shown again."
  def disagree(%Post{} = post, %User{} = admin) do
    post = Repo.preload(post, [:thread, :user])

    decide(post, admin, "disagreed", "flag.disagree", %{}, fn ->
      Post |> where([p], p.id == ^post.id) |> Repo.update_all(set: [hidden_at: nil])
      :ok
    end)
  end

  @doc "Defers the post's flags as `admin`: they're set aside, the post stays as it is."
  def defer(%Post{} = post, %User{} = admin) do
    post = Repo.preload(post, [:thread, :user])
    decide(post, admin, "deferred", "flag.defer", %{}, fn -> :ok end)
  end

  defp decision_name({:silence, _params}), do: "silence"
  defp decision_name(decision), do: Atom.to_string(decision)

  # Hiding and silencing leave the post hidden; deleting removes it.
  defp carry_out(:hide, post, _admin), do: hide(post)

  defp carry_out(:delete, post, admin) do
    result =
      case Forums.delete_post(post, admin) do
        {:error, :first_post} -> Forums.delete_thread(post.thread, admin)
        result -> result
      end

    with {:ok, _} <- result, do: :ok
  end

  defp carry_out({:silence, params}, post, admin) do
    with {:ok, _user} <- Penalties.penalize(:silence, post.user, admin, params), do: hide(post)
  end

  defp hide(post) do
    Post
    |> where([p], p.id == ^post.id and is_nil(p.hidden_at))
    |> Repo.update_all(set: [hidden_at: DateTime.utc_now(:second)])

    :ok
  end

  # Settles the pending flags as `status` and runs `action`, logged, all in
  # one transaction; then tells pages.
  defp decide(post, admin, status, log_action, details, action) do
    result =
      Repo.transact(fn ->
        {count, _} =
          Flag
          |> where([f], f.post_id == ^post.id and f.status == "pending")
          |> Repo.update_all(
            set: [
              status: status,
              reviewed_by_id: admin.id,
              reviewed_at: DateTime.utc_now(:second)
            ]
          )

        with true <- count > 0 || {:error, :no_pending_flags},
             :ok <- action.() do
          StaffLog.record(admin, log_action, post, Map.merge(post_details(post), details))
          {:ok, post}
        end
      end)

    tap_ok(result, &after_decision/1)
  end

  ## Queued posts

  @doc "Approves a queued post as `admin`: it's published and announced now."
  def approve(%Post{} = post, %User{} = admin) do
    post = Repo.preload(post, [:thread, :user])

    result =
      Repo.transact(fn ->
        {count, _} =
          Post
          |> where([p], p.id == ^post.id and not is_nil(p.queued_at) and is_nil(p.deleted_at))
          |> Repo.update_all(set: [queued_at: nil])

        if count == 1 do
          StaffLog.record(admin, "post.approve", post, post_details(post))
          {:ok, %{post | queued_at: nil}}
        else
          {:error, :not_queued}
        end
      end)

    tap_ok(result, fn approved ->
      if Forums.first_post?(approved),
        do: Forums.announce_thread(approved.thread),
        else: Forums.announce_post(approved)

      changed()
    end)
  end

  @doc """
  Rejects a queued post as `admin`, telling its author `reason`. A rejected
  thread is deleted; a rejected reply is soft-deleted (still never shown).
  """
  def reject(%Post{} = post, %User{} = admin, reason) do
    post = Repo.preload(post, [:thread, :user])
    reason = String.trim(reason || "")
    first? = Forums.first_post?(post)

    result =
      Repo.transact(fn ->
        with true <- (Post.queued?(post) and not Post.deleted?(post)) || {:error, :not_queued},
             true <- reason != "" || {:error, :reason_required},
             {:ok, _} <- remove(post, admin, first?) do
          details = Map.put(post_details(post), :reason, reason)
          StaffLog.record(admin, "post.reject", post, details)
          {:ok, post}
        end
      end)

    tap_ok(result, fn post ->
      tell_rejected(post, reason, first?)
      changed()
    end)
  end

  defp remove(post, _admin, true), do: Repo.delete(post.thread)

  defp remove(post, admin, false) do
    post
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second), deleted_by_id: admin.id)
    |> Repo.update()
  end

  defp tell_rejected(post, reason, first?) do
    {what, attrs} =
      if first?,
        do: {"thread \"#{post.thread.title}\"", %{url: "/"}},
        else:
          {"reply in \"#{post.thread.title}\"",
           %{url: FirestormWeb.Web.Paths.thread_url(post.thread), thread_id: post.thread_id}}

    {:ok, _} =
      Forums.notify(
        post.user,
        Map.merge(attrs, %{
          kind: "post_rejected",
          subject: "Staff didn't approve your #{what}",
          body: reason
        })
      )
  end

  # What the log keeps about the post, to show it once it's gone.
  defp post_details(post) do
    %{
      thread: post.thread.title,
      author: post.user && post.user.username,
      excerpt: String.slice(post.body, 0, 200)
    }
  end

  # Pages showing the post re-render it; the queue updates.
  defp after_decision(post) do
    case Repo.get(Post, post.id) do
      nil -> :ok
      current -> Forums.post_changed(:post_updated, current)
    end

    changed()
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(result, _fun), do: result

  @doc "A message for an error from this module."
  def message(:no_pending_flags), do: "Someone already reviewed those flags."
  def message(:not_queued), do: "Someone already reviewed that post."
  def message(:reason_required), do: "Say why, for the author."
  def message(reason), do: Penalties.message(reason)
end
