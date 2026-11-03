defmodule Firefly.Notifications.Dispatcher do
  @moduledoc false
  # The process behind `Firefly.Notifications`' fan-out (see its docs),
  # registered as `Firefly.Notifications`.

  use GenServer

  import Ecto.Query, only: [where: 2, order_by: 2, first: 1, select: 3]

  alias Firefly.{Discussion, Groups, Mailer, Messaging, Notifications, Repo}
  alias Firefly.Accounts.{Ignores, User}
  alias Firefly.Discussion.{Mentions, Policy, Post, Thread}
  alias Firefly.Messaging.{Conversation, Message}
  alias Firefly.Notifications.{Emails, MailingList, Notification, Subscriptions}

  @name Firefly.Notifications

  ### Client API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc "Notify subscribers about a new reply."
  def post_created(%Post{} = post), do: GenServer.cast(@name, {:post_created, post})

  @doc "Notify users newly mentioned by an edit."
  def post_edited(%Post{} = post), do: GenServer.cast(@name, {:post_edited, post})

  @doc "Notify category subscribers about a new thread."
  def thread_created(%Thread{} = thread),
    do: GenServer.cast(@name, {:thread_created, thread})

  @doc "Notify a conversation's other participants about a new message."
  def message_created(%Message{} = message),
    do: GenServer.cast(@name, {:message_created, message})

  @doc "Notify `users` that `actor` added them to a conversation."
  def participants_added(%Conversation{} = conversation, %User{} = actor, users),
    do: GenServer.cast(@name, {:participants_added, conversation, actor, users})

  ### Server API

  @impl true
  def init(_), do: {:ok, :nostate}

  @impl true
  def handle_cast({:post_created, %Post{} = post}, state) do
    with {:ok, thread, post} <- reload(post) do
      listed = MailingList.deliver(thread, post)
      fan_out("new_post", thread, post, notify_mentions(thread, post, listed), listed)
    end

    {:noreply, state}
  end

  def handle_cast({:post_edited, %Post{} = post}, state) do
    with {:ok, thread, post} <- reload(post), do: notify_mentions(thread, post)
    {:noreply, state}
  end

  def handle_cast({:thread_created, %Thread{} = thread}, state) do
    first_post =
      Post
      |> where(thread_id: ^thread.id)
      |> order_by(asc: :inserted_at, asc: :id)
      |> first()
      |> Repo.one()

    if first_post do
      post = Repo.preload(first_post, :user)
      listed = MailingList.deliver(thread, post)
      fan_out("new_thread", thread, post, notify_mentions(thread, post, listed), listed)
    end

    {:noreply, state}
  end

  def handle_cast({:message_created, %Message{} = message}, state) do
    message = Repo.preload(message, [:user, :conversation])
    conversation = message.conversation
    # The author's account may be gone by now (their messages stay).
    {author_id, author} =
      if message.user, do: {message.user.id, "@#{message.user.username}"}, else: {nil, "Someone"}

    first? = Messaging.first_message(conversation).id == message.id

    subject =
      if first?,
        do: "#{author} sent you a message: \"#{conversation.title}\"",
        else: "#{author} replied to \"#{conversation.title}\""

    recipients = Enum.reject(Messaging.participants(conversation), &(&1.id == author_id))
    muters = Ignores.muters(author_id, Enum.map(recipients, & &1.id))

    for user <- recipients, not MapSet.member?(muters, user.id) do
      notify_message(user, conversation, message, subject)
    end

    if conversation.role_id do
      skip = [author_id | Enum.map(recipients, & &1.id)]
      notify_group(conversation, message, author, first?, skip)
    end

    {:noreply, state}
  end

  def handle_cast({:participants_added, conversation, actor, users}, state) do
    message = Messaging.latest_message(conversation)
    subject = "@#{actor.username} added you to \"#{conversation.title}\""

    for user <- users, do: notify_message(user, conversation, message, subject)
    {:noreply, state}
  end

  # The group's members who aren't in the conversation, by their level.
  defp notify_group(conversation, message, author, first?, skip) do
    group = Repo.get!(Firefly.Groups.Role, conversation.role_id)
    memberships = Enum.reject(Groups.memberships(group), &(&1.user_id in skip))
    muters = Ignores.muters(message.user_id, Enum.map(memberships, & &1.user_id))

    subject =
      if first?,
        do: "#{author} messaged @#{group.name}: \"#{conversation.title}\"",
        else: "#{author} replied to \"#{conversation.title}\" (@#{group.name})"

    for %{user: user, notification_level: level} <- memberships,
        not MapSet.member?(muters, user.id),
        level in ["watching", "tracking"] or (level == "normal" and first?) do
      notify_message(user, conversation, message, subject, "group_message", level == "watching")
    end
  end

  defp notify_message(user, conversation, message, subject, kind \\ "message", email \\ true) do
    attrs = %{Notification.for_message(conversation, message, subject) | kind: kind}
    {:ok, notification} = Notifications.notify(user, attrs)

    if email and email?(user, notification) do
      Mailer.deliver_now(Emails.message_notification(user, conversation, message, subject))
      Notifications.notification_emailed(notification)
    end
  end

  # Reloaded: a post deleted (or not yet approved) before we get to it
  # notifies no one.
  defp reload(%Post{id: id}) do
    with %Post{deleted_at: nil, queued_at: nil} = post <- Repo.get(Post, id),
         %Post{thread: %Thread{} = thread} = post <- Repo.preload(post, [:user, :thread]) do
      {:ok, thread, post}
    end
  end

  # `mentioned_ids` already got a mention for this post instead. Anyone who
  # has already read the post (e.g. had the thread open) is skipped too.
  # `listed` (mailing list mode) got the post by email already.
  defp fan_out(kind, thread, post, mentioned_ids, listed) do
    already_read = Discussion.users_who_read(thread, post)

    subscribers = Subscriptions.subscribers(thread)
    readers = readers(thread, Enum.map(subscribers, &elem(&1, 0)))
    muters = Ignores.muters(post.user_id, Enum.map(subscribers, fn {user, _level} -> user.id end))

    for {user, level} <- subscribers,
        user.id != post.user_id and user.id not in mentioned_ids and
          not MapSet.member?(already_read, user.id) and not MapSet.member?(muters, user.id),
        MapSet.member?(readers, user.id) do
      {:ok, notification} =
        Notifications.notify(user, Notification.for_post(kind, thread, post, post.user))

      if level == "watching" and user.id not in listed,
        do: maybe_email(user, notification, thread, post)
    end

    :ok
  end

  # Notifies the users the post mentions who haven't been notified of a
  # mention in it yet. Returns the ids of every user mentioned in it so far.
  defp notify_mentions(thread, post, listed \\ []) do
    already =
      Notification
      |> where(post_id: ^post.id, kind: "mentioned")
      |> select([n], n.user_id)
      |> Repo.all()

    mentioned = Mentions.users(post.body)
    readers = readers(thread, mentioned)
    muters = Ignores.muters(post.user_id, Enum.map(mentioned, & &1.id))

    new =
      for user <- mentioned,
          user.id != post.user_id and user.id not in already,
          not MapSet.member?(muters, user.id),
          MapSet.member?(readers, user.id),
          Subscriptions.effective_thread_level(user, thread) != "muted" do
        {:ok, notification} =
          Notifications.notify(user, Notification.for_post("mentioned", thread, post, post.user))

        if user.id not in listed, do: maybe_email(user, notification, thread, post)
        user.id
      end

    users = already ++ new

    users ++
      Groups.notify_mentions(thread, post, post.user, users, &group_readers(thread, post, &1))
  end

  # Those of a mentioned group's `members` to notify: who may read the
  # thread, doesn't mute the author and hasn't muted the thread.
  defp group_readers(thread, post, members) do
    readers = readers(thread, members)
    muters = Ignores.muters(post.user_id, Enum.map(members, & &1.id))

    for user <- members,
        MapSet.member?(readers, user.id) and not MapSet.member?(muters, user.id),
        Subscriptions.effective_thread_level(user, thread) != "muted",
        into: MapSet.new(),
        do: user.id
  end

  # The ids of those of `users` who may read the thread, decided for all of
  # them at once rather than a :view_thread check (a few queries) each.
  defp readers(thread, users),
    do: thread |> Policy.thread_readers(users) |> MapSet.new(& &1.id)

  defp maybe_email(%User{} = user, notification, thread, post) do
    if email?(user, notification) do
      user
      |> email_for(notification.kind, thread, post)
      |> Mailer.deliver_now()

      Notifications.notification_emailed(notification)
    end
  end

  defp email?(%User{} = user, notification) do
    user.email_notifications and User.confirmed?(user) and
      not Notifications.unread_emailed_notification?(user, notification)
  end

  defp email_for(user, "mentioned", thread, post),
    do: Emails.mention_notification(user, thread, post)

  defp email_for(user, "new_thread", thread, post),
    do: Emails.thread_created_notification(user, thread, post)

  defp email_for(user, _kind, thread, post),
    do: Emails.thread_new_post_notification(user, thread, post)
end
