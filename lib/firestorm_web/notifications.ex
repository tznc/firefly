defmodule FirestormWeb.Notifications do
  @moduledoc """
  Fans out activity to subscribers (see `FirestormWeb.Forums.Subscriptions`):

    * a new thread notifies users watching or tracking its category
    * a new post notifies users watching or tracking the thread (or its
      category)

  Everyone notified gets an in-app notification; users at `watching` also get
  an email, if they have email notifications on and a confirmed address. To
  avoid floods, a thread emails a user once until they read its notifications.
  """

  use GenServer

  import Ecto.Query, only: [where: 2, order_by: 2, first: 1]

  alias FirestormWeb.{Emails, Forums, Mailer, Repo}
  alias FirestormWeb.Forums.{Notification, Post, Subscriptions, Thread, User}

  ### Client API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Notify subscribers about a new reply."
  def post_created(%Post{} = post), do: GenServer.cast(__MODULE__, {:post_created, post})

  @doc "Notify category subscribers about a new thread."
  def thread_created(%Thread{} = thread),
    do: GenServer.cast(__MODULE__, {:thread_created, thread})

  ### Server API

  @impl true
  def init(_), do: {:ok, :nostate}

  @impl true
  def handle_cast({:post_created, %Post{} = post}, state) do
    # Reloaded: a post deleted before we get to it notifies no one.
    with %Post{deleted_at: nil} = post <- Repo.get(Post, post.id),
         %Post{thread: %Thread{} = thread} = post <- Repo.preload(post, [:user, :thread]) do
      fan_out("new_post", thread, post)
    end

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
      fan_out("new_thread", thread, Repo.preload(first_post, :user))
    end

    {:noreply, state}
  end

  defp fan_out(kind, thread, post) do
    # Skip anyone who has already read this post, e.g. because they had the
    # thread open when it arrived.
    already_read = Forums.users_who_read(thread, post)

    for {user, level} <- Subscriptions.subscribers(thread),
        user.id != post.user_id and not MapSet.member?(already_read, user.id) do
      {:ok, notification} =
        Forums.notify(user, Notification.for_post(kind, thread, post, post.user))

      if level == "watching", do: maybe_email(user, notification, thread, post)
    end

    :ok
  end

  defp maybe_email(%User{} = user, notification, thread, post) do
    if user.email_notifications and User.confirmed?(user) and
         not Forums.unread_emailed_notification?(user, thread.id, notification.id) do
      user
      |> email_for(notification.kind, thread, post)
      |> Mailer.deliver_now()

      Forums.notification_emailed(notification)
    end
  end

  defp email_for(user, "new_thread", thread, post),
    do: Emails.thread_created_notification(user, thread, post)

  defp email_for(user, _kind, thread, post),
    do: Emails.thread_new_post_notification(user, thread, post)
end
