defmodule FirestormWeb.Flags do
  @moduledoc """
  Members flag posts that need staff attention (see
  `FirestormWeb.Forums.Flag`): one flag per member per post, never their own
  posts, not while silenced or suspended, and within the `:flag` rate limit.

  Flagging needs a confirmed account, so throwaway accounts can't add up
  to a hide. When a post has the `flags_to_hide` site setting's number of
  pending flags (from different members, since each flags once), it's
  hidden pending review: members see a placeholder, its author and admins
  still see it, and a hidden first post takes its thread off the lists.
  The author is notified (`post_hidden`). Admins' own posts are never
  hidden by flags; they're still flagged and reported. Admins get one
  `flagged` notification per post, updated with each new flag while
  unread. Flag counts are only for staff (the `:view_flags` policy). An
  admin can unhide a post (`unhide/2`), which dismisses its pending flags.
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Posting, Repo, SiteSettings, StaffLog}
  alias FirestormWeb.Forums.{Flag, Notification, Post, User}
  alias FirestormWeb.Web.Paths

  @doc """
  Flags `post` as `user` with `attrs` (`reason`, `note`). Errors:
  `:unauthorized` (see the `:flag_post` policy), `:already_flagged`, the
  `Posting.check/2` reasons, or an invalid changeset.
  """
  def flag_post(%Post{} = post, %User{} = user, attrs) do
    post = Repo.preload(post, [:thread, :user])

    with :ok <- Bodyguard.permit(Forums, :flag_post, user, %{post: post, thread: post.thread}),
         :ok <- Posting.check(user, :flag),
         :ok <- if(flagged?(post, user), do: {:error, :already_flagged}, else: :ok),
         {:ok, flag} <- insert(post, user, attrs) do
      maybe_hide(post)
      notify_admins(post, user)
      FirestormWeb.Review.changed()

      FirestormWeb.Plugins.Events.emit(
        "flag_raised",
        %{post_id: post.id, thread_id: post.thread_id, reason: flag.reason},
        thread: post.thread,
        actor: user
      )

      {:ok, flag}
    end
  end

  # A concurrent flag by the same user (a double submit) loses on the
  # unique index; that's the same as having flagged already.
  defp insert(post, user, attrs) do
    case %Flag{post_id: post.id, user_id: user.id} |> Flag.changeset(attrs) |> Repo.insert() do
      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :post_id), do: {:error, :already_flagged}, else: error

      result ->
        result
    end
  end

  @doc """
  Unhides a post hidden after flags, as `admin` (the `:unhide_post`
  policy): its pending flags are dismissed (`disagreed`), and the action is
  logged. `{:error, :not_hidden}` if it isn't hidden (any more).
  """
  def unhide(%Post{} = post, %User{} = admin) do
    now = DateTime.utc_now(:second)

    result =
      Repo.transact(fn ->
        {count, _} =
          Post
          |> where([p], p.id == ^post.id and not is_nil(p.hidden_at))
          |> Repo.update_all(set: [hidden_at: nil])

        if count == 1 do
          {flags, _} =
            Flag
            |> where([f], f.post_id == ^post.id and f.status == "pending")
            |> Repo.update_all(
              set: [status: "disagreed", reviewed_by_id: admin.id, reviewed_at: now]
            )

          post = Repo.preload(Repo.get!(Post, post.id), [:thread, :user])

          StaffLog.record(admin, "post.unhide", post, %{
            thread: post.thread.title,
            author: post.user && post.user.username,
            flags: flags
          })

          {:ok, post}
        else
          {:error, :not_hidden}
        end
      end)

    with {:ok, post} <- result do
      Forums.post_changed(:post_updated, post)
      FirestormWeb.Review.changed()
      {:ok, post}
    end
  end

  @doc "Whether `user` has flagged `post`."
  def flagged?(%Post{id: post_id}, %User{id: user_id}),
    do: Repo.exists?(from(f in Flag, where: f.post_id == ^post_id and f.user_id == ^user_id))

  @doc "The ids of `posts` that `user` flagged."
  def flagged_ids(_posts, nil), do: MapSet.new()

  def flagged_ids(posts, %User{id: user_id}) do
    ids = Enum.map(posts, & &1.id)

    Flag
    |> where([f], f.user_id == ^user_id and f.post_id in ^ids)
    |> select([f], f.post_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Pending flag counts for `posts` (staff only), as a map of post id to count."
  def pending_counts(posts) do
    ids = Enum.map(posts, & &1.id)

    Flag
    |> where([f], f.post_id in ^ids and f.status == "pending")
    |> group_by([f], f.post_id)
    |> select([f], {f.post_id, count(f.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp pending_flags(post) do
    Flag
    |> where([f], f.post_id == ^post.id and f.status == "pending")
    |> order_by([f], desc: f.inserted_at, desc: f.id)
    |> preload(:user)
    |> Repo.all()
  end

  # Hides the post once it has enough pending flags. The update only matches
  # a visible post, so concurrent flags hide (and notify) once. Admins' posts
  # (staff announcements, say) are left for staff to review instead.
  defp maybe_hide(post) do
    if length(pending_flags(post)) >= SiteSettings.get("flags_to_hide") and
         not (post.user && Forums.admin?(post.user)) do
      {count, _} =
        Post
        |> where([p], p.id == ^post.id and is_nil(p.hidden_at))
        |> Repo.update_all(set: [hidden_at: DateTime.utc_now(:second)])

      if count == 1 do
        :ok = FirestormWeb.Solved.clear(post.id)
        notify_author(post)
        Forums.post_changed(:post_updated, Repo.get!(Post, post.id))
      end
    end
  end

  defp notify_author(post) do
    {:ok, _} =
      Forums.notify(post.user, %{
        kind: "post_hidden",
        subject: "Your post in \"#{post.thread.title}\" was hidden after members flagged it",
        body:
          "Staff will review it. Until then only you and staff can see it. " <>
            "If they find nothing wrong, it will be shown again.",
        url: url(post),
        thread_id: post.thread_id,
        post_id: post.id
      })
  end

  # One unread notification per admin and post, kept up to date.
  defp notify_admins(post, flagger) do
    flags = pending_flags(post)

    attrs = %{
      kind: "flagged",
      subject:
        "#{length(flags)} #{if length(flags) == 1, do: "flag", else: "flags"} on " <>
          "@#{post.user.username}'s post in \"#{post.thread.title}\"",
      body: Enum.map_join(flags, "\n", &flag_line/1),
      url: url(post),
      thread_id: post.thread_id,
      post_id: post.id
    }

    for admin <- admins(), admin.id != flagger.id do
      unread =
        Notification
        |> where([n], n.user_id == ^admin.id and n.post_id == ^post.id and n.kind == "flagged")
        |> where([n], is_nil(n.read_at))
        |> first()
        |> Repo.one()

      if unread do
        {:ok, _} =
          unread |> Ecto.Changeset.change(Map.take(attrs, [:subject, :body])) |> Repo.update()

        Forums.notifications_changed(admin.id)
      else
        {:ok, _} = Forums.notify(admin, attrs)
      end
    end
  end

  defp flag_line(flag) do
    "@#{flag.user.username}: #{Flag.reason_label(flag.reason)}" <>
      if(flag.note, do: " (#{flag.note})", else: "")
  end

  defp admins do
    User
    |> join(:inner, [u], r in assoc(u, :roles))
    |> where([u, r], r.name == "admin" and is_nil(u.deleted_at))
    |> Repo.all()
  end

  defp url(post), do: "#{Paths.thread_url(post.thread)}#post-#{post.id}"

  @doc "A message for an error from `flag_post/3`."
  def message(:unauthorized), do: "You can't flag that post."
  def message(:already_flagged), do: "You already flagged this post."
  def message(:unconfirmed), do: "Please confirm your email address before flagging posts."
  def message(:not_hidden), do: "That post isn't hidden."
  def message(reason), do: Posting.message(reason)
end
