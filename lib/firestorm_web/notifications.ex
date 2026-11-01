defmodule FirestormWeb.Notifications do
  @moduledoc """
  Fans out activity to subscribers (see `FirestormWeb.Forums.Subscriptions`):

    * a new thread notifies users watching or tracking its category
    * a new post notifies users watching or tracking the thread (or its
      category)
    * only users who may read the thread (the `:view_thread` policy) are
      notified of anything in it: watching a tag or category, or a thread
      that has since moved, gives no access to restricted categories
    * a new or edited post notifies the users it @mentions (see
      `FirestormWeb.Mentions`), once per post: an edit only notifies users it
      newly mentions. Not the author, users who can't see the thread (the
      `:view_thread` policy) or users who muted it. A mentioned user gets the
      mention instead of the new thread/post notification.
    * a private message notifies the conversation's other participants, and
      adding people to a conversation notifies them (see
      `FirestormWeb.Messages`)

  Everyone notified gets an in-app notification; users at `watching`,
  mentioned users and message recipients also get an email, if they have
  email notifications on and a confirmed address. To avoid floods, a thread
  (or conversation) emails a user once until they read its notifications.
  """

  use GenServer

  import Ecto.Query, only: [where: 2, order_by: 2, first: 1, select: 3]

  alias FirestormWeb.{Emails, Forums, Mailer, Mentions, Messages, Repo}

  alias FirestormWeb.Forums.{
    Conversation,
    Message,
    Notification,
    Post,
    Subscriptions,
    Thread,
    User
  }

  ### Client API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Notify subscribers about a new reply."
  def post_created(%Post{} = post), do: GenServer.cast(__MODULE__, {:post_created, post})

  @doc "Notify users newly mentioned by an edit."
  def post_edited(%Post{} = post), do: GenServer.cast(__MODULE__, {:post_edited, post})

  @doc "Notify category subscribers about a new thread."
  def thread_created(%Thread{} = thread),
    do: GenServer.cast(__MODULE__, {:thread_created, thread})

  @doc "Notify a conversation's other participants about a new message."
  def message_created(%Message{} = message),
    do: GenServer.cast(__MODULE__, {:message_created, message})

  @doc "Notify `users` that `actor` added them to a conversation."
  def participants_added(%Conversation{} = conversation, %User{} = actor, users),
    do: GenServer.cast(__MODULE__, {:participants_added, conversation, actor, users})

  ### Server API

  @impl true
  def init(_), do: {:ok, :nostate}

  @impl true
  def handle_cast({:post_created, %Post{} = post}, state) do
    with {:ok, thread, post} <- reload(post) do
      fan_out("new_post", thread, post, notify_mentions(thread, post))
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
      fan_out("new_thread", thread, post, notify_mentions(thread, post))
    end

    {:noreply, state}
  end

  def handle_cast({:message_created, %Message{} = message}, state) do
    message = Repo.preload(message, [:user, :conversation])
    conversation = message.conversation
    author = message.user
    first? = Messages.first_message(conversation).id == message.id

    subject =
      if first?,
        do: "@#{author.username} sent you a message: \"#{conversation.title}\"",
        else: "@#{author.username} replied to \"#{conversation.title}\""

    for user <- Messages.participants(conversation), user.id != author.id do
      notify_message(user, conversation, message, subject)
    end

    {:noreply, state}
  end

  def handle_cast({:participants_added, conversation, actor, users}, state) do
    message = Messages.latest_message(conversation)
    subject = "@#{actor.username} added you to \"#{conversation.title}\""

    for user <- users, do: notify_message(user, conversation, message, subject)
    {:noreply, state}
  end

  defp notify_message(user, conversation, message, subject) do
    {:ok, notification} =
      Forums.notify(user, Notification.for_message(conversation, message, subject))

    if email?(user, notification) do
      Mailer.deliver_now(Emails.message_notification(user, conversation, message, subject))
      Forums.notification_emailed(notification)
    end
  end

  # Reloaded: a post deleted before we get to it notifies no one.
  defp reload(%Post{id: id}) do
    with %Post{deleted_at: nil} = post <- Repo.get(Post, id),
         %Post{thread: %Thread{} = thread} = post <- Repo.preload(post, [:user, :thread]) do
      {:ok, thread, post}
    end
  end

  # `mentioned_ids` already got a mention for this post instead.
  defp fan_out(kind, thread, post, mentioned_ids) do
    for {user, level} <- Subscriptions.subscribers(thread),
        user.id != post.user_id and user.id not in mentioned_ids,
        Bodyguard.permit?(Forums, :view_thread, user, thread) do
      {:ok, notification} =
        Forums.notify(user, Notification.for_post(kind, thread, post, post.user))

      if level == "watching", do: maybe_email(user, notification, thread, post)
    end

    :ok
  end

  # Notifies the users the post mentions who haven't been notified of a
  # mention in it yet. Returns the ids of every user mentioned in it so far.
  defp notify_mentions(thread, post) do
    already =
      Notification
      |> where(post_id: ^post.id, kind: "mentioned")
      |> select([n], n.user_id)
      |> Repo.all()

    new =
      for user <- post.body |> Mentions.usernames() |> Forums.users_by_username() |> Map.values(),
          user.id != post.user_id and user.id not in already,
          Bodyguard.permit?(Forums, :view_thread, user, thread),
          Subscriptions.effective_thread_level(user, thread) != "muted" do
        {:ok, notification} =
          Forums.notify(user, Notification.for_post("mentioned", thread, post, post.user))

        maybe_email(user, notification, thread, post)
        user.id
      end

    already ++ new
  end

  defp maybe_email(%User{} = user, notification, thread, post) do
    if email?(user, notification) do
      email =
        if notification.kind == "mentioned",
          do: Emails.mention_notification(user, thread, post),
          else: Emails.thread_new_post_notification(user, thread, post)

      Mailer.deliver_now(email)

      Forums.notification_emailed(notification)
    end
  end

  defp email?(%User{} = user, notification) do
    user.email_notifications and User.confirmed?(user) and
      not Forums.unread_emailed_notification?(user, notification)
  end
end
