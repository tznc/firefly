defmodule Firefly.Notifications.EmailWorker do
  @moduledoc """
  Sends one notification email (or mailing list post) as a background job
  in the `mailers` queue, built from the records when it runs: 3 attempts,
  each in the email log. Jobs hold ids, never message text (staff see jobs
  in the dashboard). Unique per notification, or per post and member
  in mailing list mode, for good: however often the fan-out runs, nobody
  gets the same email twice.
  """
  use Oban.Worker,
    queue: :mailers,
    max_attempts: 3,
    unique: [
      keys: [:template, :notification_id, :user_id, :post_id],
      period: :infinity,
      states: :all
    ]

  alias Firefly.{Mailer, Notifications, Repo}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Post, Thread}
  alias Firefly.Messaging.{Conversation, Message}
  alias Firefly.Notifications.{Emails, Notification}

  @doc """
  Queues the email about `notification` (`args`: its `template` and the
  records it's built from), and marks the notification emailed now, so the
  once-per-thread throttle counts it at once.
  """
  def send_later(%Notification{} = notification, args) do
    {:ok, _job} =
      args
      |> Map.merge(%{notification_id: notification.id, user_id: notification.user_id})
      |> new()
      |> Firefly.Jobs.insert()

    Notifications.notification_emailed(notification)
  end

  @doc "Queues the mailing list email of `post` in `thread` for `user`."
  def mailing_list_later(%User{id: user_id}, %Thread{id: thread_id}, %Post{id: post_id}) do
    %{template: "mailing_list_post", user_id: user_id, thread_id: thread_id, post_id: post_id}
    |> new()
    |> Firefly.Jobs.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with %User{} = user <- Repo.get(User, args["user_id"]),
         %Swoosh.Email{} = email <- build(args["template"], user, args) do
      case Mailer.deliver_now(email) do
        {:ok, _sent} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      # Whatever it was about is gone.
      _gone -> :ok
    end
  end

  defp build("post_notification", user, args) do
    with %Notification{kind: kind} <- Repo.get(Notification, args["notification_id"]),
         %Thread{} = thread <- Repo.get(Thread, args["thread_id"]),
         %Post{} = post <- Repo.preload(Repo.get(Post, args["post_id"]), :user) do
      email_for(user, kind, thread, post)
    end
  end

  defp build("message_notification", user, args) do
    with %Conversation{} = conversation <- Repo.get(Conversation, args["conversation_id"]),
         %Message{} = message <- Repo.get(Message, args["message_id"]),
         do: Emails.message_notification(user, conversation, message, args["subject"])
  end

  defp build("chat_notification", user, args) do
    with %Firefly.Chat.Message{deleted_at: nil, body: body} <-
           Repo.get(Firefly.Chat.Message, args["message_id"]),
         do: Emails.chat_notification(user, args["subject"], body, args["url"])
  end

  defp build("mailing_list_post", user, args) do
    with %Thread{} = thread <- Repo.get(Thread, args["thread_id"]),
         %Post{} = post <- Repo.preload(Repo.get(Post, args["post_id"]), :user),
         do: Emails.mailing_list_post(user, thread, post)
  end

  defp email_for(user, kind, thread, post) when kind in ["mentioned", "group_mentioned"],
    do: Emails.mention_notification(user, thread, post)

  defp email_for(user, "new_thread", thread, post),
    do: Emails.thread_created_notification(user, thread, post)

  defp email_for(user, _kind, thread, post),
    do: Emails.thread_new_post_notification(user, thread, post)
end
