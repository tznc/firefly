defmodule Firefly.Notifications do
  @moduledoc """
  The Notifications context: in-app notifications, notification levels,
  emails, digests and browser push.

  Fans out activity to subscribers (see `Firefly.Notifications.Subscriptions`):

    * a new thread notifies users watching or tracking its category
    * a new post notifies users watching or tracking the thread (or its
      category)
    * only users who may read the thread (the `:view_thread` policy) are
      notified of anything in it: watching a tag or category, or a thread
      that has since moved, gives no access to restricted categories
    * a new or edited post notifies the users it @mentions (see
      `Firefly.Discussion.Mentions`), once per post: an edit only notifies users it
      newly mentions. Not the author, users who can't see the thread (the
      `:view_thread` policy) or users who muted it. A mentioned user gets the
      mention instead of the new thread/post notification.
    * a post @mentioning a group notifies its members (those who may read
      the thread and didn't mute it), if the author may mention the group
      (see `Firefly.Groups.notify_mentions/5`); once per post, like
      user mentions
    * a private message notifies the conversation's other participants, and
      adding people to a conversation notifies them (see
      `Firefly.Messaging`). A message to a group's inbox also notifies
      the group's other members by their group notification level:
      `watching` (every message, emailed), `tracking` (every message),
      `normal` (new conversations) or `muted` (nothing)
    * a chat message notifies the users it mentions and the members at
      the `always` level (direct messages' default), as `Firefly.Chat.notify/2`
      decides

  Nobody is notified of what a user they mute or ignore did (see
  `Firefly.Accounts.Ignores`).

  Members in mailing list mode get every new post by email instead of
  notification emails about posts (see
  `Firefly.Notifications.MailingList`).

  Everyone notified gets an in-app notification; users at `watching`,
  mentioned users and message recipients also get an email, if they have
  email notifications on and a confirmed address. To avoid floods, a thread
  (or conversation) emails a user once until they read its notifications.

  The fan-out runs as a background job after the change is saved
  (`Firefly.Notifications.FanOut`, retried when it fails), and each email
  and browser push is a job of its own, unique per notification: a retry
  never notifies, emails or pushes anyone twice. (Tests run the jobs
  themselves, with the test support's `run_notifications()`.)

  Its public modules besides this one: `Firefly.Notifications.Notification`
  (the schema), `Subscriptions` (watching, tracking and muting threads,
  categories and tags), `Emails`, `Digests`, `WebPush`, `ReplyAddress`
  and `EmailLog` (every email sent, for staff).
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [
      Notification,
      Subscriptions,
      Watch,
      CategoryWatch,
      TagWatch,
      Emails,
      Digests,
      WebPush,
      ReplyAddress,
      MailingList,
      EmailLog
    ]

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [change: 2]

  alias Firefly.Repo
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Policy, Thread}
  alias Firefly.Notifications.{FanOut, Notification, Subscriptions}

  ## Fan-out (background jobs, see `Firefly.Notifications.FanOut`)

  @doc "Notify subscribers about a new reply."
  def post_created(%Firefly.Discussion.Post{id: id}), do: fan_out("post_created", %{post_id: id})

  @doc "Notify users newly mentioned by an edit."
  def post_edited(%Firefly.Discussion.Post{id: id}), do: fan_out("post_edited", %{post_id: id})

  @doc "Notify category subscribers about a new thread."
  def thread_created(%Thread{id: id}), do: fan_out("thread_created", %{thread_id: id})

  @doc "Notify a conversation's other participants about a new message."
  def message_created(%Firefly.Messaging.Message{id: id}),
    do: fan_out("message_created", %{message_id: id})

  @doc "Notify `users` that `actor` added them to a conversation."
  def participants_added(%Firefly.Messaging.Conversation{id: id}, %User{id: actor_id}, users) do
    fan_out("participants_added", %{
      conversation_id: id,
      actor_id: actor_id,
      user_ids: Enum.map(users, & &1.id)
    })
  end

  @doc """
  Notify about a chat message: the users with ids `mentioned_ids` it
  newly mentions, and those who hear about every message in its channel
  (see `Firefly.Chat.notify/2`).
  """
  def chat_message_created(%{id: id}, mentioned_ids),
    do: fan_out("chat_message_created", %{message_id: id, mentioned_ids: mentioned_ids})

  # In the caller's transaction, so nothing is lost if it commits.
  defp fan_out(event, args) do
    {:ok, _job} = Firefly.Jobs.insert(FanOut.job(event, args))
    :ok
  end

  ## In-app notifications

  @doc "Have a user watch a thread (notification level `watching`)."
  def watch(%User{} = user, %Thread{} = thread),
    do: Subscriptions.set_thread_level(user, thread, "watching")

  @doc "Stop watching a thread (notification level `normal`)."
  def unwatch(%User{} = user, %Thread{} = thread) do
    {:ok, _} = Subscriptions.set_thread_level(user, thread, "normal")
    :ok
  end

  @doc "Whether the user watches the thread (by their own choice on the thread)."
  def watched_by?(%Thread{} = thread, %User{} = user),
    do: Subscriptions.thread_level(user, thread) == "watching"

  @doc """
  The user's notifications, newest first. Like everything else, they leave
  out threads the user may no longer read (say, moved into a restricted
  category).
  """
  def notifications_for(%User{} = user) do
    user
    |> visible_notifications()
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(100)
    |> Repo.all()
  end

  def unread_notification_count(%User{} = user) do
    user
    |> visible_notifications()
    |> where([n], is_nil(n.read_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Sends a notification to a user, tells their open pages so the badge
  updates live, and pushes it to their browsers (see `Firefly.Notifications.WebPush`).
  """
  def notify(%User{} = user, attrs) do
    result =
      %Notification{}
      |> Notification.changeset(Map.put(attrs, :user_id, user.id))
      |> Repo.insert()

    with {:ok, notification} <- result do
      Firefly.Telemetry.execute([:firefly, :notifications, :created], %{count: 1}, %{
        kind: notification.kind
      })

      notifications_changed(user.id)
      Firefly.Notifications.WebPush.notification_created(user, notification)
    end

    result
  end

  @doc """
  Emails `notification` in the background, once (see
  `Firefly.Notifications.EmailWorker`): `args` names the `template` and what
  it's built from.
  """
  defdelegate email_later(notification, args),
    to: Firefly.Notifications.EmailWorker,
    as: :send_later

  @doc """
  Notifies `user` like `notify/2`, unless they already have a notification
  of the same kind about the same thing (its URL): then that one. The
  fan-out uses it, so running it again (a retried job) notifies no one
  twice.
  """
  def notify_once(%User{} = user, %{kind: kind, url: url} = attrs) do
    existing =
      Repo.one(
        from(n in Notification,
          where: n.user_id == ^user.id and n.kind == ^kind and n.url == ^url,
          limit: 1
        )
      )

    if existing, do: {:ok, existing}, else: notify(user, attrs)
  end

  def mark_notification_read(%Notification{read_at: nil} = notification) do
    {:ok, notification} =
      notification |> change(read_at: DateTime.utc_now(:second)) |> Repo.update()

    notifications_changed(notification.user_id)
    {:ok, notification}
  end

  def mark_notification_read(%Notification{} = notification), do: {:ok, notification}

  def mark_all_notifications_read(%User{} = user) do
    Notification
    |> where([n], n.user_id == ^user.id and is_nil(n.read_at))
    |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])
    |> case do
      {0, _} -> :ok
      _ -> notifications_changed(user.id)
    end
  end

  @doc "Marks the notification as emailed."
  def notification_emailed(%Notification{} = notification) do
    notification |> change(emailed_at: DateTime.utc_now(:second)) |> Repo.update()
  end

  @doc """
  Whether the user already has an unread, emailed notification about the
  same thread or conversation as `notification`. Used to send one email per
  thread (or conversation) until the user comes back.
  """
  def unread_emailed_notification?(%User{} = user, %Notification{} = notification) do
    about =
      cond do
        notification.conversation_id ->
          dynamic([n], n.conversation_id == ^notification.conversation_id)

        notification.chat_channel_id ->
          dynamic([n], n.chat_channel_id == ^notification.chat_channel_id)

        true ->
          dynamic([n], n.thread_id == ^notification.thread_id)
      end

    Notification
    |> where([n], n.user_id == ^user.id and n.id != ^notification.id)
    |> where(^about)
    |> where([n], is_nil(n.read_at) and not is_nil(n.emailed_at))
    |> Repo.exists?()
  end

  # Threads, bound as `:thread` (see `Policy.readable_threads/2`).
  defp threads_query, do: from(t in Thread, as: :thread)

  defp visible_notifications(user) do
    readable = threads_query() |> Policy.readable_threads(user) |> select([t], t.id)

    Notification
    |> where([n], n.user_id == ^user.id)
    |> where(
      [n],
      not is_nil(n.conversation_id) or
        (is_nil(n.thread_id) and n.kind in ^Notification.threadless_kinds()) or
        n.thread_id in subquery(readable)
    )
  end

  def notifications_topic(user_id), do: "user:#{user_id}:notifications"

  @doc """
  Tells the user's open pages their notifications (or unread messages)
  changed, so the badges update.
  """
  def notifications_changed(user_id) do
    Phoenix.PubSub.broadcast(
      Firefly.PubSub,
      notifications_topic(user_id),
      :notifications_changed
    )
  end

  @doc "One of `user`'s notifications (see `notifications_for/1`), or nil."
  def get_notification(%User{} = user, id) do
    user
    |> visible_notifications()
    |> Repo.get(id)
  end
end
