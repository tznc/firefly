defmodule Firefly.Chat.Notifier do
  @moduledoc false
  # Who hears of a chat message, and how (see `Firefly.Chat.notify/2`).

  import Ecto.Query

  alias Firefly.{Notifications, Repo, URLs}
  alias Firefly.Accounts.{Ignores, User}
  alias Firefly.Chat.{Channel, Membership, Message}
  alias Firefly.Notifications.Notification

  # Someone not seen for this long is away: mentions and direct messages
  # are emailed to them too.
  @away_minutes 10

  def notify(%Message{id: id}, mentioned_ids) do
    case Repo.get(Message, id) do
      %Message{deleted_at: nil, user_id: author_id} = message when is_integer(author_id) ->
        message = Repo.preload(message, [:user, :channel])
        fan_out(message, mentioned_ids)

      _deleted_or_gone ->
        :ok
    end
  end

  defp fan_out(%Message{user: author, channel: channel} = message, mentioned_ids) do
    memberships =
      Membership
      |> where([m], m.channel_id == ^channel.id and m.user_id != ^author.id)
      |> preload(:user)
      |> Repo.all()

    by_user = Map.new(memberships, &{&1.user_id, &1})
    mentioned = Repo.all(from(u in User, where: u.id in ^mentioned_ids))
    muters = Ignores.muters(author.id, Enum.map(memberships, & &1.user_id) ++ mentioned_ids)
    hears? = &hears?(&1, by_user[&1.id], message, muters)

    for user <- mentioned, hears?.(user), do: deliver(user, "chat_mention", message)

    for %{user: user, following: true, notification_level: "always"} <- memberships,
        user.id not in mentioned_ids,
        hears?.(user),
        not unread_about?(user, channel),
        do: deliver(user, "chat_message", message)

    :ok
  end

  # Not those who mute or ignore the author, muted the channel, turned its
  # notifications off or have already read the message (had it open).
  defp hears?(user, membership, message, muters) do
    is_nil(user.deleted_at) and not MapSet.member?(muters, user.id) and
      (is_nil(membership) or
         (not membership.muted and membership.notification_level != "never" and
            (membership.last_read_message_id || 0) < message.id))
  end

  # One unread notification per channel at a time for every-message news.
  defp unread_about?(user, channel) do
    Repo.exists?(
      from(n in Notification,
        where: n.user_id == ^user.id and n.chat_channel_id == ^channel.id,
        where: n.kind == "chat_message" and is_nil(n.read_at)
      )
    )
  end

  defp deliver(user, kind, %Message{user: author, channel: channel} = message) do
    subject = subject(kind, author, channel)
    url = URLs.chat_channel_url(channel) <> "?message=#{message.id}"

    # Like private messages, direct messages stay out of stored
    # notifications (admins can see those).
    body =
      if Channel.direct?(channel),
        do: "Open chat to read it.",
        else: String.slice(message.body, 0, 300)

    {:ok, notification} =
      Notifications.notify_once(user, %{
        kind: kind,
        subject: subject,
        body: body,
        url: url,
        chat_channel_id: channel.id
      })

    if email?(user, kind, channel, notification) do
      Notifications.email_later(notification, %{
        template: "chat_notification",
        subject: subject,
        # The body is read when the email is built: no message text in jobs.
        message_id: message.id,
        url: url
      })
    end
  end

  defp subject("chat_mention", author, %Channel{kind: "direct"}),
    do: "@#{author.username} mentioned you in a direct message"

  defp subject("chat_mention", author, channel),
    do: "@#{author.username} mentioned you in ##{channel.name}"

  defp subject("chat_message", author, %Channel{kind: "direct"}),
    do: "@#{author.username} sent you a direct message"

  defp subject("chat_message", author, channel),
    do: "@#{author.username} wrote in ##{channel.name}"

  # Mentions and direct messages, for members who are away, once per
  # channel until they've read its notifications.
  defp email?(user, kind, channel, notification) do
    (kind == "chat_mention" or Channel.direct?(channel)) and away?(user) and
      user.email_notifications and User.confirmed?(user) and
      not Notifications.unread_emailed_notification?(user, notification)
  end

  defp away?(%User{last_seen_at: nil}), do: true

  defp away?(%User{last_seen_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at, :minute) >= @away_minutes
end
