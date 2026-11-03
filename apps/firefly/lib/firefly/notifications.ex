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
  alias Firefly.Notifications.{Dispatcher, Notification, Subscriptions}

  ## Fan-out (asynchronous, see `Firefly.Notifications.Dispatcher`)

  @doc false
  defdelegate child_spec(opts), to: Dispatcher

  @doc "Starts the fan-out process (the app does; tests start their own)."
  defdelegate start_link(opts \\ []), to: Dispatcher

  @doc "Notify subscribers about a new reply."
  defdelegate post_created(post), to: Dispatcher

  @doc "Notify users newly mentioned by an edit."
  defdelegate post_edited(post), to: Dispatcher

  @doc "Notify category subscribers about a new thread."
  defdelegate thread_created(thread), to: Dispatcher

  @doc "Notify a conversation's other participants about a new message."
  defdelegate message_created(message), to: Dispatcher

  @doc "Notify `users` that `actor` added them to a conversation."
  defdelegate participants_added(conversation, actor, users), to: Dispatcher

  @doc """
  Notify about a chat message: the users with ids `mentioned_ids` it
  newly mentions, and those who hear about every message in its channel
  (see `Firefly.Chat.notify/2`).
  """
  defdelegate chat_message_created(message, mentioned_ids), to: Dispatcher

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
      notifications_changed(user.id)
      Firefly.Notifications.WebPush.notification_created(user, notification)
    end

    result
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
