defmodule Firefly.Chat do
  @moduledoc """
  The Chat context: real-time chat in channels and direct messages, as
  Discourse's chat (without voice or video).

  Channels (`Firefly.Chat.Channel`) are either category channels, which
  staff create and anyone who may read the channel's category (or anyone,
  without one) can follow, or direct message channels between two or
  more people (at most `chat_max_direct_message_users`): the same people
  always share one. Who may chat at all, and who may start direct
  messages, are the `chat_allowed_groups` and
  `direct_message_enabled_groups` site settings (see
  `Firefly.Chat.Policy`, also for what each action needs). Staff close
  (only staff post), make read-only, archive and reopen channels, logged
  in the staff log.

  Members (`Firefly.Chat.Membership`) follow channels, mute them and pick
  their notification level; their read position gives the unread and
  mention counts (`my_channels/1`). Messages are Markdown, rendered like
  posts (emoji, uploads, link previews, mentions, watched words). They are
  edited (keeping revisions), soft-deleted and restored by their author or
  staff, quote the message they reply to (`in_reply_to_id`) or go into a
  thread (`thread_of`), whose replies stay out of the channel's stream and
  have their own read position. Members react with emoji, pin messages
  (staff in category channels, anyone in a direct message) and search the
  messages they may read (`search/3`).

  Sending goes through the posting gate (`Firefly.Moderation.Posting.check/2`
  with `:chat`: read-only mode, penalties, confirmation and the `:chat`
  rate limit) and watched words (blocked words refuse the message; censored,
  replaced and linked words render so; a silencing word silences its
  author). Messages from users the reader ignores are left out (see
  `Firefly.Accounts.Ignores`).

  ## Notifications and moderation

  A message notifies (`notify/2`, through `Firefly.Notifications`: in-app,
  browser push, and email for members away for 10 minutes) the users it
  mentions: `@username`, `@group` (if the author may mention the group),
  and, where the channel allows them and the author has the
  `chat_channel_wide_mentions_min_trust` trust level, `@all` (everyone
  following the channel) and `@here` (those of them seen in the last 5
  minutes). Members at the `always` level (direct messages' default) hear
  of every message, one unread notification per channel at a time. Nobody
  hears what a user they mute or ignore wrote, nor about a channel they
  muted or set to `never`, nor what they've already read. Reading a
  channel reads its notifications.

  Members flag messages (`flag_message/3`) into the staff review queue
  (see `Firefly.Moderation.Review`), as a `flag` watched word does; staff
  agree (the message is deleted) or disagree, logged. Staff remove members
  from channels. The `chat_channel_retention_days` and
  `chat_dm_retention_days` settings delete old messages (`run_due/0`,
  hourly).

  Plugins and webhooks get `chat_message_created`, `_edited`, `_deleted`
  and `chat_channel_created` (see `Firefly.Plugins.Events`; plugins only
  for channels anyone may read).

  ## Live events

    * `"chat:channel:<id>"` (`subscribe/1`) - `{:message_created, message}`,
      `{:message_updated, message}` (edited, deleted, restored),
      `{:channel_updated, channel}` and `{:typing, %{channel_id, user_id,
      username, thread_id}}`
    * `"chat:user:<id>"` (`subscribe_user/1`) - `{:chat_read, channel_id}`
      when the user read a channel elsewhere, and `:channels_changed` when
      their list changed (followed, left, a new direct message)
    * `"chat:channels"` (`subscribe_channels/0`) - `:channels_changed` when
      staff create or change a channel

  Presence in a channel is tracked by the web interface on
  `presence_topic/1`.
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [
      Channel,
      Flag,
      Message,
      MessageRevision,
      Membership,
      Reaction,
      Thread,
      ThreadMembership
    ]

  import Ecto.Query
  import Ecto.Changeset, only: [change: 2, put_change: 3]

  alias Firefly.{
    Accounts,
    Groups,
    JobRuns,
    Notifications,
    RateLimit,
    Repo,
    SiteSettings,
    TrustLevels
  }

  alias Firefly.Accounts.{Ignores, User}

  alias Firefly.Chat.{
    Channel,
    Flag,
    Membership,
    Mention,
    Message,
    MessageRevision,
    Notifier,
    Policy,
    Reaction,
    Thread,
    ThreadMembership
  }

  alias Firefly.Discussion.Mentions
  alias Firefly.Moderation.{Posting, Review, StaffLog, WatchedWords}
  alias Firefly.Notifications.Notification
  alias Firefly.Plugins.Events
  alias Firefly.Uploads.Upload
  alias Firefly.Rendering.Emoji

  @page 50

  ## Permissions

  @doc "Whether chat is on (the `chat_enabled` site setting)."
  def enabled?, do: SiteSettings.get("chat_enabled")

  @doc "Whether `user` may take `action` (see `Firefly.Chat.Policy`)."
  def can?(user, action, params \\ nil), do: Policy.authorize(action, user, params) == :ok

  defp authorized(user, action, params) do
    if can?(user, action, params), do: :ok, else: {:error, :unauthorized}
  end

  ## Channels

  @doc "The channel with `id` (an integer or a string), or nil."
  def get_channel(id) when is_integer(id), do: Repo.get(Channel, id)

  def get_channel(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> get_channel(id)
      _other -> nil
    end
  end

  @doc "A changeset for the channel form."
  def change_channel(channel \\ %Channel{}, attrs \\ %{}), do: Channel.changeset(channel, attrs)

  @doc "Creates a category channel as `admin`, who follows it."
  def create_channel(attrs, %User{} = admin) do
    changeset = Channel.changeset(%Channel{kind: "category", created_by_id: admin.id}, attrs)

    with :ok <- authorized(admin, :manage_channel, nil),
         {:ok, channel} <-
           save_logged(changeset, admin, "chat_channel.create", &%{name: &1.name, slug: &1.slug}) do
      Repo.insert!(%Membership{channel_id: channel.id, user_id: admin.id}, on_conflict: :nothing)
      channels_changed()
      user_changed(admin.id)
      emit("chat_channel_created", channel, fn -> %{channel: channel_data(channel)} end, admin)
      {:ok, channel}
    end
  end

  @doc "Changes a category channel's name, slug, description or category, as `admin`."
  def update_channel(%Channel{kind: "category"} = channel, attrs, %User{} = admin) do
    changeset = Channel.changeset(channel, attrs)

    details = &Map.put(StaffLog.changes(changeset), :name, &1.name)

    with :ok <- authorized(admin, :manage_channel, nil),
         {:ok, updated} <- save_logged(changeset, admin, "chat_channel.update", details) do
      channel_updated(updated)
      {:ok, updated}
    end
  end

  @doc """
  Sets a category channel's status (`"open"`, `"closed"`, `"read_only"`
  or `"archived"`) as `admin`.
  """
  def set_status(%Channel{kind: "category"} = channel, status, %User{} = admin) do
    changeset = Channel.status_changeset(channel, status)

    details = &%{name: &1.name, status: %{before: channel.status, after: &1.status}}

    with :ok <- authorized(admin, :manage_channel, nil),
         {:ok, updated} <- save_logged(changeset, admin, "chat_channel.status", details) do
      channel_updated(updated)
      {:ok, updated}
    end
  end

  # Saves the channel and logs `action` as `admin`, with the details
  # `details` makes of the saved channel, in one transaction.
  defp save_logged(changeset, admin, action, details) do
    Repo.transact(fn ->
      with {:ok, channel} <- Repo.insert_or_update(changeset) do
        StaffLog.record(admin, action, {"chat_channel", channel.id}, details.(channel))
        {:ok, channel}
      end
    end)
  end

  defp channel_updated(channel) do
    broadcast(channel.id, {:channel_updated, channel})
    channels_changed()
  end

  @doc """
  The category channels `user` may view, by name, each with whether they
  follow it: `{channel, following?}`. Archived channels only if they do.
  """
  def browse_channels(%User{} = user) do
    Channel
    |> Policy.viewable_category_channels(user)
    |> join(:left, [c], m in Membership, on: m.channel_id == c.id and m.user_id == ^user.id)
    |> where([c, m], c.status != "archived" or m.following)
    |> order_by([c], fragment("lower(?)", c.name))
    |> select([c, m], {c, coalesce(m.following, false)})
    |> Repo.all()
  end

  @doc """
  The channels in `user`'s list: `%{channels: [...], direct: [...]}`, each
  entry `%{channel, membership, unread, mentions}`. Category channels they
  follow and may still view (a member who lost access to the category
  loses the channel), by name; direct messages, most recently active first,
  with their `members`.
  """
  def my_channels(%User{} = user) do
    viewable = Channel |> Policy.viewable_category_channels(user) |> select([c], c.id)

    rows =
      Channel
      |> join(:inner, [c], m in Membership,
        on: m.channel_id == c.id and m.user_id == ^user.id and m.following
      )
      |> where([c], c.kind == "direct" or c.id in subquery(viewable))
      |> select([c, m], {c, m})
      |> Repo.all()

    counts = unread_counts(user, Enum.map(rows, fn {channel, _} -> channel.id end))
    channels = rows |> Enum.map(&elem(&1, 0)) |> with_members()

    entries =
      Enum.zip_with(channels, rows, fn channel, {_channel, membership} ->
        Map.merge(%{channel: channel, membership: membership}, counts[channel.id])
      end)

    {direct, category} = Enum.split_with(entries, &Channel.direct?(&1.channel))

    %{
      channels: Enum.sort_by(category, &String.downcase(&1.channel.name)),
      direct: Enum.sort_by(direct, &(&1.channel.last_message_at || &1.channel.inserted_at), :desc)
    }
  end

  @doc "How many channels have unread messages for `user` (muted ones aside)."
  def unread_channel_count(%User{} = user) do
    %{channels: channels, direct: direct} = my_channels(user)
    Enum.count(channels ++ direct, &(&1.unread > 0 and not &1.membership.muted))
  end

  # By channel id: `%{unread, mentions}`. Unread: messages in the channel's
  # stream (not thread replies) by others since the read position, deleted
  # and ignored users' left out. Mentions: of `user`, since then, anywhere
  # in the channel.
  defp unread_counts(user, ids) do
    ignored = Ignores.ignored_ids(user)

    unread =
      Message
      |> join(:inner, [m], mb in Membership,
        on: mb.channel_id == m.channel_id and mb.user_id == ^user.id
      )
      |> join(:left, [m], t in Thread, on: t.id == m.thread_id)
      |> where([m, mb], m.channel_id in ^ids and m.id > coalesce(mb.last_read_message_id, 0))
      |> where([m], is_nil(m.deleted_at) and m.user_id != ^user.id and m.user_id not in ^ignored)
      |> where([m, _mb, t], is_nil(t.id) or t.original_message_id == m.id)
      |> group_by([m], m.channel_id)
      |> select([m], {m.channel_id, count(m.id)})
      |> Repo.all()
      |> Map.new()

    mentions =
      Mention
      |> join(:inner, [x], m in Message, on: m.id == x.message_id)
      |> join(:inner, [x, m], mb in Membership,
        on: mb.channel_id == m.channel_id and mb.user_id == ^user.id
      )
      |> where([x, m, mb], x.user_id == ^user.id and m.channel_id in ^ids)
      |> where([x, m, mb], m.id > coalesce(mb.last_read_message_id, 0) and is_nil(m.deleted_at))
      |> group_by([x, m], m.channel_id)
      |> select([x, m], {m.channel_id, count(x.id)})
      |> Repo.all()
      |> Map.new()

    Map.new(ids, &{&1, %{unread: Map.get(unread, &1, 0), mentions: Map.get(mentions, &1, 0)}})
  end

  # Direct message channels get their `members`, by username.
  defp with_members(channels) do
    ids = for %Channel{kind: "direct", id: id} <- channels, do: id

    members =
      User
      |> join(:inner, [u], m in Membership, on: m.user_id == u.id and m.channel_id in ^ids)
      |> order_by([u], asc: u.username)
      |> select([u, m], {m.channel_id, u})
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(channels, &%{&1 | members: Map.get(members, &1.id, [])})
  end

  @doc """
  The channel's name for `viewer`: a category channel's name, or a direct
  message's other members (`"@bob, @carol"`).
  """
  def title(%Channel{kind: "category", name: name}, _viewer), do: name

  def title(%Channel{kind: "direct"} = channel, %User{id: viewer_id}) do
    [channel] = if channel.members == [], do: with_members([channel]), else: [channel]

    case Enum.reject(channel.members, &(&1.id == viewer_id)) do
      [] -> "@" <> Enum.map_join(channel.members, ", @", & &1.username)
      others -> "@" <> Enum.map_join(others, ", @", & &1.username)
    end
  end

  @doc "The users following the channel, by username."
  def members(%Channel{id: id}) do
    User
    |> join(:inner, [u], m in Membership,
      on: m.user_id == u.id and m.channel_id == ^id and m.following
    )
    |> order_by([u], asc: u.username)
    |> Repo.all()
  end

  @doc "`user`'s membership of the channel, or nil."
  def membership(%Channel{id: id}, %User{id: user_id}),
    do: Repo.get_by(Membership, channel_id: id, user_id: user_id)

  def membership(_channel, nil), do: nil

  @doc """
  Follows a category channel `user` may view: it joins their list, read up
  to now.
  """
  def follow(%Channel{kind: "category"} = channel, %User{} = user) do
    with :ok <- authorized(user, :view_channel, channel) do
      Repo.insert!(
        %Membership{
          channel_id: channel.id,
          user_id: user.id,
          last_read_message_id: latest_message_id(channel.id)
        },
        on_conflict: [set: [following: true, updated_at: NaiveDateTime.utc_now()]],
        conflict_target: [:channel_id, :user_id]
      )

      user_changed(user.id)
      :ok
    end
  end

  @doc """
  Takes the channel off `user`'s list. A direct message comes back with
  its next message.
  """
  def unfollow(%Channel{id: id}, %User{id: user_id}) do
    Membership
    |> where([m], m.channel_id == ^id and m.user_id == ^user_id)
    |> Repo.update_all(set: [following: false, updated_at: NaiveDateTime.utc_now()])

    user_changed(user_id)
    :ok
  end

  @doc "Sets `user`'s `muted` and `notification_level` for a channel they're in."
  def update_membership(%Channel{} = channel, %User{} = user, attrs) do
    case membership(channel, user) do
      nil ->
        {:error, :not_member}

      membership ->
        with {:ok, membership} <-
               membership |> Membership.settings_changeset(attrs) |> Repo.update() do
          user_changed(user.id)
          {:ok, membership}
        end
    end
  end

  ## Direct messages

  @doc """
  The direct message channel between `sender` and the users named in
  `usernames` (with or without `@`), made if it doesn't exist yet, and
  in the sender's list. Errors: `:unauthorized`, or a message about the
  recipients.
  """
  def direct_channel(%User{} = sender, usernames) when is_list(usernames) do
    with :ok <- authorized(sender, :create_direct_message, nil),
         {:ok, users} <- direct_recipients(sender, usernames) do
      ids = Enum.sort([sender.id | Enum.map(users, & &1.id)])
      key = Enum.join(ids, ",")

      {:ok, channel} = Repo.transact(fn -> open_direct(key, ids, sender) end)
      user_changed(sender.id)
      {:ok, channel}
    end
  end

  defp open_direct(key, ids, sender) do
    Repo.insert!(%Channel{kind: "direct", direct_key: key, created_by_id: sender.id},
      on_conflict: :nothing,
      conflict_target: :direct_key
    )

    channel = Repo.get_by!(Channel, direct_key: key)
    now = NaiveDateTime.utc_now()

    # The others see it once there's a message (see `send_message/3`).
    rows =
      for id <- ids do
        %{
          channel_id: channel.id,
          user_id: id,
          following: id == sender.id,
          notification_level: "always",
          muted: false,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Membership, rows, on_conflict: :nothing)

    Membership
    |> where([m], m.channel_id == ^channel.id and m.user_id == ^sender.id)
    |> Repo.update_all(set: [following: true])

    {:ok, channel}
  end

  defp direct_recipients(sender, names) do
    names =
      names
      |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("@")))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq_by(&String.downcase/1)

    found = Accounts.users_by_username(names)
    unknown = Enum.reject(names, &Map.has_key?(found, &1))
    users = found |> Map.values() |> Enum.reject(&(&1.id == sender.id)) |> Enum.uniq_by(& &1.id)
    max = SiteSettings.get("chat_max_direct_message_users")
    closed = closed_to(users, sender)

    cond do
      unknown != [] -> {:error, "no such user: #{at(unknown)}"}
      users == [] -> {:error, "add at least one other person"}
      length(users) + 1 > max -> {:error, "a direct message can have at most #{max} people"}
      closed != [] -> {:error, "#{at(Enum.map(closed, & &1.username))} can't be messaged"}
      true -> {:ok, users}
    end
  end

  # Those who can't chat, and (except for admins sending) those who turned
  # private messages off or mute or ignore the sender, told apart from
  # neither, so an ignore stays private.
  defp closed_to(users, sender) do
    muters =
      if Accounts.admin?(sender),
        do: nil,
        else: Ignores.muters(sender.id, Enum.map(users, & &1.id))

    Enum.filter(users, fn user ->
      not can?(user, :use_chat) or
        (muters != nil and (not user.allow_private_messages or MapSet.member?(muters, user.id)))
    end)
  end

  defp at(names), do: Enum.map_join(names, ", ", &"@#{&1}")

  ## Messages

  @doc """
  A page of the channel's stream (thread replies left out), oldest first,
  as `viewer` sees it (messages from users they ignore left out): the
  latest `#{@page}`, or those `before:` or `after:` a message id, or half
  a page each side of the one `around:` (`limit:` to change the size).
  """
  def messages(channel, viewer, opts \\ [])

  def messages(%Channel{} = channel, %User{} = viewer, around: id) do
    half = div(@page, 2)

    messages(channel, viewer, before: id + 1, limit: half) ++
      messages(channel, viewer, after: id, limit: half)
  end

  def messages(%Channel{id: id}, %User{} = viewer, opts) do
    limit = opts[:limit] || @page

    query =
      Message
      |> join(:left, [m], t in Thread, on: t.id == m.thread_id)
      |> where([m, t], m.channel_id == ^id and (is_nil(t.id) or t.original_message_id == m.id))
      |> without_ignored(viewer)

    {query, order} =
      cond do
        opts[:before] -> {where(query, [m], m.id < ^opts[:before]), :desc}
        opts[:after] -> {where(query, [m], m.id > ^opts[:after]), :asc}
        true -> {query, :desc}
      end

    query
    |> order_by([m], [{^order, m.id}])
    |> limit(^limit)
    |> Repo.all()
    |> Enum.sort_by(& &1.id)
    |> for_display()
  end

  @doc "A thread's messages, its original message first, as `viewer` sees them."
  def thread_messages(%Thread{id: id}, %User{} = viewer) do
    Message
    |> where([m], m.thread_id == ^id)
    |> without_ignored(viewer)
    |> order_by(asc: :id)
    |> Repo.all()
    |> for_display()
  end

  defp without_ignored(query, viewer) do
    case Ignores.ignored_ids(viewer) do
      [] -> query
      ids -> where(query, [m], is_nil(m.user_id) or m.user_id not in ^ids)
    end
  end

  @doc "The message ready to show (author, quoted message, thread and reply count)."
  def display(%Message{} = message), do: hd(for_display([message]))

  defp for_display(messages) do
    messages =
      Repo.preload(messages, [:user, :deleted_by, :thread, reactions: :user, in_reply_to: :user])

    counts = reply_counts(for m <- messages, m.thread_id, do: m.thread_id)

    Enum.map(messages, fn message ->
      if message.thread && message.thread.original_message_id == message.id,
        do: %{message | reply_count: Map.get(counts, message.thread_id, 0)},
        else: message
    end)
  end

  defp reply_counts([]), do: %{}

  defp reply_counts(thread_ids) do
    Message
    |> join(:inner, [m], t in Thread, on: t.id == m.thread_id)
    |> where([m, t], m.thread_id in ^thread_ids and m.id != t.original_message_id)
    |> where([m], is_nil(m.deleted_at))
    |> group_by([m], m.thread_id)
    |> select([m], {m.thread_id, count(m.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The channel's threads, most recently replied to first, each with its
  original message (ready to show) and `unread` replies for `viewer`
  (when they take part).
  """
  def threads(%Channel{id: id} = channel, %User{} = viewer) do
    threads =
      Thread
      |> where([t], t.channel_id == ^id and not is_nil(t.last_reply_at))
      |> order_by(desc: :last_reply_at)
      |> limit(50)
      |> preload(:original_message)
      |> Repo.all()

    originals =
      threads |> Enum.map(& &1.original_message) |> for_display() |> Map.new(&{&1.id, &1})

    unread = thread_unread_counts(channel, viewer)

    for thread <- threads do
      %{
        thread: thread,
        original: originals[thread.original_message_id],
        unread: Map.get(unread, thread.id, 0)
      }
    end
  end

  @doc "The message with `id`, with its channel, or nil."
  def get_message(id) do
    case Repo.get(Message, id) do
      nil -> nil
      message -> Repo.preload(message, :channel)
    end
  end

  @doc "The thread with `id`, or nil."
  def get_thread(id), do: Repo.get(Thread, id)

  @doc "Whether `viewer` may read the message with `id` (for its uploads)."
  def message_readable?(id, viewer) do
    case get_message(id) do
      nil -> false
      message -> can?(viewer, :view_channel, message.channel)
    end
  end

  @doc "The message's earlier bodies, oldest first, with who edited."
  def revisions(%Message{id: id}) do
    MessageRevision
    |> where([r], r.message_id == ^id)
    |> order_by(asc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Sends a message to the channel as `user`. `attrs`: `body`, and
  optionally `in_reply_to_id` (a message in the channel it quotes) or
  `thread_of` (a message in the channel whose thread it replies in; the
  first reply starts the thread). Errors: `:unauthorized`, `:not_found`
  (no such message to reply to), the `Firefly.Moderation.Posting.check/2`
  reasons, or an invalid changeset.
  """
  def send_message(%Channel{} = channel, %User{} = user, attrs) do
    channel = Repo.get!(Channel, channel.id)

    with :ok <- authorized(user, :post_message, channel),
         :ok <- Posting.check(user, :chat),
         {:ok, reply_to} <- in_channel(channel, param(attrs, :in_reply_to_id)),
         {:ok, thread_of} <- in_channel(channel, param(attrs, :thread_of)),
         {:ok, {message, refollowed, mentioned}} <-
           insert_message(channel, user, attrs, reply_to, thread_of) do
      message = display(message)
      broadcast(channel.id, {:message_created, message})
      Enum.each(refollowed, &user_changed/1)
      announce("chat_message_created", message, channel, user, mentioned)
      :ok = Firefly.Moderation.Akismet.chat_sent(message, user)
      {:ok, message}
    end
  end

  defp param(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp in_channel(_channel, blank) when blank in [nil, ""], do: {:ok, nil}

  defp in_channel(channel, id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Message{deleted_at: nil} = message <-
           Repo.get_by(Message, id: id, channel_id: channel.id) do
      {:ok, message}
    else
      _ -> {:error, :not_found}
    end
  end

  defp insert_message(channel, user, attrs, reply_to, thread_of) do
    changeset =
      %Message{channel_id: channel.id, user_id: user.id, in_reply_to_id: reply_to && reply_to.id}
      |> Message.changeset(attrs)
      |> WatchedWords.validate(user)
      |> Mentions.validate_count(Mentions.max_mentions())

    if changeset.valid? do
      Repo.transact(fn -> save_message(changeset, channel, user, thread_of) end)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp save_message(changeset, channel, user, thread_of) do
    thread = thread_of && start_thread(thread_of)
    message = changeset |> put_change(:thread_id, thread && thread.id) |> Repo.insert!()
    at = message.inserted_at

    Repo.update_all(where(Channel, id: ^channel.id), set: [last_message_at: at])
    :ok = Firefly.Uploads.attach(message.body, user, message)

    if thread do
      Repo.update_all(where(Thread, id: ^thread.id), set: [last_reply_at: at])
      join_thread(thread, user.id, message.id, :replace)
    end

    mentioned = mention(message, channel, user)
    read_own(channel, user, message, is_nil(thread))
    {:ok, {message, refollow(channel), mentioned}}
  end

  # The message's thread, started if it has none yet (its author takes part).
  defp start_thread(%Message{thread_id: id}) when is_integer(id), do: Repo.get!(Thread, id)

  defp start_thread(%Message{} = original) do
    Repo.insert!(%Thread{channel_id: original.channel_id, original_message_id: original.id},
      on_conflict: :nothing,
      conflict_target: :original_message_id
    )

    thread = Repo.get_by!(Thread, original_message_id: original.id)
    Repo.update_all(where(Message, id: ^original.id), set: [thread_id: thread.id])
    if original.user_id, do: join_thread(thread, original.user_id, original.id, :keep)
    thread
  end

  defp join_thread(thread, user_id, read_id, on_conflict) do
    on_conflict =
      if on_conflict == :keep,
        do: :nothing,
        else: [set: [last_read_message_id: read_id, updated_at: NaiveDateTime.utc_now()]]

    Repo.insert!(
      %ThreadMembership{thread_id: thread.id, user_id: user_id, last_read_message_id: read_id},
      on_conflict: on_conflict,
      conflict_target: [:thread_id, :user_id]
    )
  end

  # The sender follows the channel, read up to their message if it's in
  # the stream (a thread reply leaves the stream's position alone).
  defp read_own(channel, user, message, in_stream?) do
    now = NaiveDateTime.utc_now()

    set =
      if in_stream?,
        do: [following: true, last_read_message_id: message.id, updated_at: now],
        else: [following: true, updated_at: now]

    level = if Channel.direct?(channel), do: "always", else: "mention"

    Repo.insert!(
      %Membership{
        channel_id: channel.id,
        user_id: user.id,
        notification_level: level,
        last_read_message_id: message.id
      },
      on_conflict: [set: set],
      conflict_target: [:channel_id, :user_id]
    )
  end

  # A direct message is back in the list of members who left it. Returns
  # their ids.
  defp refollow(%Channel{kind: "direct", id: id}) do
    {_count, ids} =
      Membership
      |> where([m], m.channel_id == ^id and not m.following)
      |> select([m], m.user_id)
      |> Repo.update_all(set: [following: true])

    ids
  end

  defp refollow(_channel), do: []

  # Records the users the message mentions who may read the channel (not
  # its author; see the moduledoc). Returns the ids of those it didn't
  # mention before (an edit can add some).
  defp mention(message, channel, author) do
    users = Mentions.users(message.body)
    taken = MapSet.new(users, &String.downcase(&1.username))

    rest =
      message.body
      |> Mentions.usernames()
      |> Enum.reject(&MapSet.member?(taken, String.downcase(&1)))

    ids =
      (users ++ group_members(rest, author) ++ channel_wide(rest, channel, author))
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&(&1.id != author.id and can?(&1, :view_channel, channel)))
      |> Enum.map(& &1.id)

    before = Repo.all(from(x in Mention, where: x.message_id == ^message.id, select: x.user_id))
    now = NaiveDateTime.utc_now()

    Repo.insert_all(
      Mention,
      Enum.map(ids, &%{message_id: message.id, user_id: &1, inserted_at: now}),
      on_conflict: :nothing
    )

    ids -- before
  end

  defp group_members(names, author) do
    names
    |> Groups.by_names()
    |> Map.values()
    |> Enum.filter(&Groups.can_mention?(&1, author))
    |> Enum.flat_map(&Groups.members/1)
    |> Enum.map(fn {user, _owner?} -> user end)
  end

  @here_minutes 5

  # @all: everyone following the channel; @here: those of them seen lately.
  defp channel_wide(names, channel, author) do
    wanted = names |> Enum.map(&String.downcase/1) |> Enum.filter(&(&1 in ~w(all here)))

    if wanted == [] or not channel.allow_channel_wide_mentions or
         not TrustLevels.allowed?(author, "chat_channel_wide_mentions_min_trust") do
      []
    else
      followers =
        from(u in User,
          join: m in Membership,
          on: m.user_id == u.id and m.channel_id == ^channel.id and m.following
        )

      since = DateTime.add(DateTime.utc_now(), -@here_minutes, :minute)

      query =
        if "all" in wanted, do: followers, else: where(followers, [u], u.last_seen_at >= ^since)

      Repo.all(query)
    end
  end

  # After a message is saved (or edited): notifications, plugins and
  # webhooks, and the author's watched words (a `flag` word flags it).
  defp announce(event, message, channel, author, mentioned) do
    :ok = Notifications.chat_message_created(message, mentioned)

    emit(
      event,
      channel,
      fn -> %{message: message_data(message, channel), channel: channel_data(channel)} end,
      author
    )

    case WatchedWords.written(message.body, author) do
      [] -> :ok
      words -> flag_by_system(message, "Watched words: " <> Enum.join(words, ", "))
    end
  end

  defp emit(event, channel, data, actor) do
    channel = Repo.preload(channel, :category)

    Events.emit(event, data,
      category: channel.category,
      private: Channel.direct?(channel),
      actor: actor
    )
  end

  defp channel_data(channel),
    do: %{
      id: channel.id,
      name: channel.name,
      slug: channel.slug,
      kind: channel.kind,
      category_id: channel.category_id,
      url: Firefly.URLs.chat_channel_url(channel)
    }

  defp message_data(message, channel) do
    message = Repo.preload(message, :user)

    %{
      id: message.id,
      channel_id: message.channel_id,
      thread_id: message.thread_id,
      user_id: message.user_id,
      author: message.user && message.user.username,
      body: message.body,
      url: Firefly.URLs.chat_channel_url(channel) <> "?message=#{message.id}"
    }
  end

  @doc """
  Edits `user`'s own message (the earlier body is kept as a revision).
  Newly mentioned users are counted as mentioned.
  """
  def edit_message(%Message{} = message, %User{} = user, attrs) do
    message = Repo.preload(Repo.get!(Message, message.id), :channel)

    changeset =
      message
      |> Message.changeset(attrs)
      |> WatchedWords.validate(user)
      |> Mentions.validate_count(Mentions.max_mentions())

    with :ok <- authorized(user, :edit_message, message),
         :ok <- Posting.check(user, :like),
         true <- changeset.valid? || {:error, %{changeset | action: :update}} do
      if changeset.changes == %{},
        do: {:ok, display(message)},
        else: edited(message, changeset, user)
    end
  end

  defp edited(message, changeset, user) do
    {:ok, {edited, mentioned}} = Repo.transact(fn -> save_edit(message, changeset, user) end)
    edited = display(edited)
    broadcast(edited.channel_id, {:message_updated, edited})
    announce("chat_message_edited", edited, message.channel, user, mentioned)
    {:ok, edited}
  end

  defp save_edit(message, changeset, user) do
    Repo.insert!(%MessageRevision{
      message_id: message.id,
      user_id: user.id,
      body: message.body
    })

    edited =
      changeset |> put_change(:edited_at, DateTime.utc_now(:second)) |> Repo.update!()

    :ok = Firefly.Uploads.attach(edited.body, user, edited)
    {:ok, {edited, mention(edited, message.channel, user)}}
  end

  @doc """
  Soft-deletes a message as `actor` (its author, or staff: logged). It
  shows as deleted; the author or staff can restore it.
  """
  def delete_message(%Message{} = message, %User{} = actor) do
    message = Repo.preload(Repo.get!(Message, message.id), [:channel, :user])

    with :ok <- authorized(actor, :delete_message, message),
         :ok <- Posting.check(actor, :like) do
      {:ok, deleted} =
        Repo.transact(fn ->
          deleted =
            message
            |> change(deleted_at: DateTime.utc_now(:second), deleted_by_id: actor.id)
            |> Repo.update!()

          log(actor, "chat_message.delete", message)
          {:ok, deleted}
        end)

      deleted = display(deleted)
      broadcast(deleted.channel_id, {:message_updated, deleted})
      emit_deleted(deleted, message.channel, actor)
      {:ok, deleted}
    end
  end

  @doc "Restores a deleted message as `actor` (see `:restore_message`; staff are logged)."
  def restore_message(%Message{} = message, %User{} = actor) do
    message = Repo.preload(Repo.get!(Message, message.id), [:channel, :user])

    with :ok <- authorized(actor, :restore_message, message),
         :ok <- Posting.check(actor, :like) do
      {:ok, restored} =
        Repo.transact(fn ->
          restored = message |> change(deleted_at: nil, deleted_by_id: nil) |> Repo.update!()
          log(actor, "chat_message.restore", message)
          {:ok, restored}
        end)

      restored = display(restored)
      broadcast(restored.channel_id, {:message_updated, restored})
      {:ok, restored}
    end
  end

  # What members do to their own messages isn't staff action (pinning is,
  # whoever wrote it).
  defp log(actor, action, message, whose \\ :others)
  defp log(%User{id: id}, _action, %Message{user_id: id}, :others), do: nil

  defp log(actor, action, message, _whose) do
    StaffLog.record(actor, action, {"chat_message", message.id}, %{
      channel: message.channel.name || "direct message",
      author: message.user && message.user.username,
      excerpt: String.slice(message.body, 0, 200)
    })
  end

  ## Reactions and pins

  @doc """
  Adds `user`'s `emoji` reaction to the message, or takes it back if
  they'd reacted so. Counts against the `:like` rate limit.
  """
  def toggle_reaction(%Message{} = message, %User{} = user, emoji) do
    message = Repo.preload(Repo.get!(Message, message.id), :channel)

    with :ok <- authorized(user, :react, message),
         :ok <- Posting.check(user, :like),
         :ok <- valid_emoji(emoji),
         :ok <- RateLimit.check_like(user) do
      case Repo.get_by(Reaction, message_id: message.id, user_id: user.id, emoji: emoji) do
        nil ->
          Repo.insert!(%Reaction{message_id: message.id, user_id: user.id, emoji: emoji},
            on_conflict: :nothing
          )

        reaction ->
          Repo.delete!(reaction)
      end

      updated(message)
    end
  end

  # A custom emoji by name, or a short run of characters that aren't
  # letters, digits, spaces or markup (a standard emoji).
  defp valid_emoji(":" <> rest) do
    name = String.trim_trailing(rest, ":")
    if Map.has_key?(Emoji.custom(), name), do: :ok, else: {:error, :invalid_emoji}
  end

  defp valid_emoji(emoji) when is_binary(emoji) do
    if String.length(emoji) in 1..2 and not String.match?(emoji, ~r/[\s<>&"'\w:]/u),
      do: :ok,
      else: {:error, :invalid_emoji}
  end

  defp valid_emoji(_emoji), do: {:error, :invalid_emoji}

  @doc """
  The message's reactions grouped by emoji, in the order first used:
  `[%{emoji, users}]` (usernames). Needs `reactions` loaded (see
  `display/1`).
  """
  def reaction_groups(%Message{reactions: reactions}) when is_list(reactions) do
    reactions
    |> Enum.group_by(& &1.emoji)
    |> Enum.map(fn {emoji, list} ->
      %{emoji: emoji, users: Enum.map(list, & &1.user.username), first: hd(list).id}
    end)
    |> Enum.sort_by(& &1.first)
  end

  @doc "Pins the message to its channel (see `:pin_message`; staff are logged)."
  def pin_message(%Message{} = message, %User{} = user),
    do: set_pin(message, user, DateTime.utc_now(:second), "chat_message.pin")

  @doc "Unpins the message."
  def unpin_message(%Message{} = message, %User{} = user),
    do: set_pin(message, user, nil, "chat_message.unpin")

  defp set_pin(message, user, at, action) do
    message = Repo.preload(Repo.get!(Message, message.id), [:channel, :user])

    with :ok <- authorized(user, :pin_message, message),
         :ok <- Posting.check(user, :like) do
      {:ok, _} = Repo.transact(fn -> save_pin(message, user, at, action) end)
      updated(message)
    end
  end

  # Staff pinning in a category channel is logged.
  defp save_pin(message, user, at, action) do
    message |> change(pinned_at: at, pinned_by_id: at && user.id) |> Repo.update!()
    if message.channel.kind == "category", do: log(user, action, message, :always)
    {:ok, message}
  end

  defp updated(message) do
    updated = display(Repo.get!(Message, message.id))
    broadcast(updated.channel_id, {:message_updated, updated})
    {:ok, updated}
  end

  @doc "The channel's pinned messages, most recently pinned first."
  def pinned_messages(%Channel{id: id}, %User{} = viewer) do
    Message
    |> where([m], m.channel_id == ^id and not is_nil(m.pinned_at) and is_nil(m.deleted_at))
    |> without_ignored(viewer)
    |> order_by(desc: :pinned_at, desc: :id)
    |> Repo.all()
    |> for_display()
  end

  ## Search

  @doc """
  The messages matching `terms` (web search syntax: words, `"phrases"`,
  `-excluded`) that `user` may read, newest first, at most 50, with their
  channel. `channel:` narrows it to one channel.
  """
  def search(%User{} = user, terms, opts \\ []) do
    terms = String.trim(terms || "")

    if terms == "" do
      []
    else
      viewable = Channel |> Policy.viewable_category_channels(user) |> select([c], c.id)
      direct = from(m in Membership, where: m.user_id == ^user.id, select: m.channel_id)

      Message
      |> join(:inner, [m], c in Channel, on: c.id == m.channel_id)
      |> where(
        [m, c],
        (c.kind == "category" and c.id in subquery(viewable)) or
          (c.kind == "direct" and c.id in subquery(direct))
      )
      |> where([m], is_nil(m.deleted_at))
      |> where([m], fragment("? @@ websearch_to_tsquery('english', ?)", m.search_vector, ^terms))
      |> in_channel_filter(opts[:channel])
      |> without_ignored(user)
      |> order_by(desc: :id)
      |> limit(50)
      |> Repo.all()
      |> for_display()
      |> Repo.preload(:channel)
    end
  end

  defp in_channel_filter(query, nil), do: query
  defp in_channel_filter(query, %Channel{id: id}), do: where(query, [m], m.channel_id == ^id)

  ## Read positions

  @doc "Where `user` had read up to in the channel (a message id), or nil."
  def last_read_message_id(%Channel{} = channel, %User{} = user) do
    case membership(channel, user) do
      nil -> nil
      membership -> membership.last_read_message_id
    end
  end

  @doc """
  Moves `user`'s read position in the channel forward, to `message_id` or
  the channel's newest message (thread replies included, so mentions in
  threads count as read too). Their other pages hear of it.
  """
  def mark_read(%Channel{id: id}, %User{id: user_id}, message_id \\ nil) do
    message_id = message_id || latest_message_id(id)

    if message_id do
      {moved, _} =
        Membership
        |> where([m], m.channel_id == ^id and m.user_id == ^user_id)
        |> where([m], is_nil(m.last_read_message_id) or m.last_read_message_id < ^message_id)
        |> Repo.update_all(set: [last_read_message_id: message_id])

      if moved > 0, do: broadcast_user(user_id, {:chat_read, id})
    end

    {read, _} =
      Notification
      |> where([n], n.user_id == ^user_id and n.chat_channel_id == ^id and is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])

    if read > 0, do: Notifications.notifications_changed(user_id)
    :ok
  end

  defp latest_message_id(channel_id),
    do: Repo.one(from(m in Message, where: m.channel_id == ^channel_id, select: max(m.id)))

  @doc "Marks the thread read up to its newest message, for a user taking part in it."
  def mark_thread_read(%Thread{id: id, channel_id: channel_id}, %User{id: user_id}) do
    latest = Repo.one(from(m in Message, where: m.thread_id == ^id, select: max(m.id)))

    {moved, _} =
      ThreadMembership
      |> where([t], t.thread_id == ^id and t.user_id == ^user_id)
      |> where([t], is_nil(t.last_read_message_id) or t.last_read_message_id < ^latest)
      |> Repo.update_all(set: [last_read_message_id: latest])

    if moved > 0, do: broadcast_user(user_id, {:chat_read, channel_id})
    :ok
  end

  @doc """
  The threads in the channel `user` takes part in that have replies they
  haven't read: thread id => how many.
  """
  def thread_unread_counts(%Channel{id: id}, %User{id: user_id}) do
    Message
    |> join(:inner, [m], tm in ThreadMembership,
      on: tm.thread_id == m.thread_id and tm.user_id == ^user_id
    )
    |> where([m, tm], m.channel_id == ^id and m.id > coalesce(tm.last_read_message_id, 0))
    |> where([m], is_nil(m.deleted_at) and m.user_id != ^user_id)
    |> group_by([m], m.thread_id)
    |> select([m], {m.thread_id, count(m.id)})
    |> Repo.all()
    |> Map.new()
  end

  ## Notifications

  @doc """
  Notifies about a new or edited message (run by `Firefly.Notifications`'
  fan-out): the users with ids `mentioned_ids` (newly mentioned) and the
  members at the `always` level, as the moduledoc says.
  """
  defdelegate notify(message, mentioned_ids), to: Notifier

  ## Flags

  @doc """
  Flags a message as `user` (`reason`, `note`, as post flags), for the
  staff review queue. Errors: `:unauthorized` (see `:flag_message`),
  `:already_flagged`, the `Posting.check(user, :flag)` reasons, or an
  invalid changeset.
  """
  def flag_message(%Message{} = message, %User{} = user, attrs) do
    message = Repo.preload(Repo.get!(Message, message.id), [:channel, :user])

    with :ok <- authorized(user, :flag_message, message),
         :ok <- Posting.check(user, :flag),
         {:ok, flag} <- insert_flag(%Flag{message_id: message.id, user_id: user.id}, attrs) do
      Review.changed()
      {:ok, flag}
    end
  end

  # A concurrent flag by the same user loses on the unique index.
  defp insert_flag(flag, attrs) do
    case flag |> Flag.changeset(attrs) |> Repo.insert() do
      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :message_id), do: {:error, :already_flagged}, else: error

      result ->
        result
    end
  end

  @doc """
  Flags a message as the system (a watched word, Akismet), `note` saying
  why, `reason` `"other"` unless given.
  """
  def flag_by_system(%Message{} = message, note, reason \\ "other") do
    {:ok, flag} = insert_flag(%Flag{message_id: message.id}, %{reason: reason, note: note})
    Review.changed()
    {:ok, flag}
  end

  @doc "How many chat messages have pending flags."
  def pending_flag_count do
    Repo.one(
      from(f in Flag, where: f.status == "pending", select: count(f.message_id, :distinct))
    )
  end

  @doc """
  The messages with pending flags, longest-waiting first, with their
  channel (direct messages' members loaded), author and pending flags.
  """
  def flagged_messages do
    pending =
      from(f in Flag, where: f.status == "pending", order_by: f.inserted_at, preload: :user)

    Message
    |> join(:inner, [m], f in Flag, on: f.message_id == m.id and f.status == "pending")
    |> group_by([m], m.id)
    |> order_by([m, f], asc: min(f.inserted_at))
    |> preload([:user, :channel, flags: ^pending])
    |> Repo.all()
    |> Enum.map(&%{&1 | channel: hd(with_members([&1.channel]))})
  end

  @doc """
  Settles a message's pending flags as `admin`: `:agree` deletes the
  message, `:disagree` leaves it. Logged. `{:error, :no_pending_flags}`
  if someone already did.
  """
  def review_flags(%Message{} = message, %User{} = admin, decision)
      when decision in [:agree, :disagree] do
    message = Repo.preload(Repo.get!(Message, message.id), [:channel, :user])

    with :ok <- authorized(admin, :manage_channel, nil),
         {:ok, settled} <- Repo.transact(fn -> settle(message, admin, decision) end) do
      if decision == :agree do
        {:ok, _} = updated(settled)
        emit_deleted(settled, message.channel, admin)
      end

      :ok =
        Firefly.Moderation.Akismet.chat_reviewed(
          message.id,
          if(decision == :agree, do: :spam, else: :ham)
        )

      Review.changed()
      {:ok, settled}
    end
  end

  defp settle(message, admin, decision) do
    now = DateTime.utc_now(:second)
    status = if decision == :agree, do: "agreed", else: "disagreed"

    {count, _} =
      Flag
      |> where([f], f.message_id == ^message.id and f.status == "pending")
      |> Repo.update_all(set: [status: status, reviewed_by_id: admin.id, reviewed_at: now])

    cond do
      count == 0 ->
        {:error, :no_pending_flags}

      decision == :agree ->
        log(admin, "chat_flag.agree", message, :always)
        {:ok, delete_now(message, admin, now)}

      true ->
        log(admin, "chat_flag.disagree", message, :always)
        {:ok, message}
    end
  end

  defp delete_now(%Message{deleted_at: nil} = message, admin, now),
    do: message |> change(deleted_at: now, deleted_by_id: admin.id) |> Repo.update!()

  defp delete_now(message, _admin, _now), do: message

  defp emit_deleted(message, channel, actor),
    do:
      emit(
        "chat_message_deleted",
        channel,
        %{message_id: message.id, channel_id: channel.id},
        actor
      )

  ## Staff

  @doc "Takes `member` out of a category channel, as `admin` (logged)."
  def remove_member(%Channel{kind: "category"} = channel, %User{} = member, %User{} = admin) do
    with :ok <- authorized(admin, :manage_channel, nil) do
      {:ok, _} =
        Repo.transact(fn ->
          Repo.delete_all(where(Membership, channel_id: ^channel.id, user_id: ^member.id))

          StaffLog.record(admin, "chat_channel.remove_member", {"chat_channel", channel.id}, %{
            name: channel.name,
            username: member.username
          })

          {:ok, channel}
        end)

      user_changed(member.id)
      :ok
    end
  end

  @doc """
  Deletes messages older than the retention settings (once an hour across
  nodes; run by `Firefly.Moderation.TopicTimers.Scheduler`). Their uploads
  are left unattached, for the orphan cleanup.
  """
  def run_due(now \\ NaiveDateTime.utc_now()) do
    if JobRuns.claim("chat.retention", 3600) do
      prune("category", SiteSettings.get("chat_channel_retention_days"), now)
      prune("direct", SiteSettings.get("chat_dm_retention_days"), now)
    end

    :ok
  end

  defp prune(_kind, 0, _now), do: 0

  defp prune(kind, days, now) do
    cutoff = NaiveDateTime.add(now, -days, :day)
    channels = from(c in Channel, where: c.kind == ^kind, select: c.id)

    old =
      from(m in Message,
        where: m.inserted_at < ^cutoff and m.channel_id in subquery(channels),
        select: m.id
      )

    {:ok, count} = Repo.transact(fn -> delete_old(old) end)
    count
  end

  defp delete_old(old) do
    Upload
    |> where([u], u.chat_message_id in subquery(old))
    |> Repo.update_all(set: [attached_to: nil, chat_message_id: nil])

    {count, _} = Repo.delete_all(from(m in Message, where: m.id in subquery(old)))
    {:ok, count}
  end

  ## Accounts

  @doc """
  `user`'s chat data, for their account export: the messages they sent,
  their channels (direct messages unnamed) and their reactions.
  """
  def export(%User{id: id}) do
    %{
      messages:
        Repo.all(
          from(m in Message,
            join: c in Channel,
            on: c.id == m.channel_id,
            where: m.user_id == ^id,
            order_by: m.id,
            select: %{
              id: m.id,
              channel: coalesce(c.name, "direct message"),
              body: m.body,
              inserted_at: m.inserted_at,
              edited_at: m.edited_at,
              deleted_at: m.deleted_at
            }
          )
        ),
      channels:
        Repo.all(
          from(m in Membership,
            join: c in Channel,
            on: c.id == m.channel_id,
            where: m.user_id == ^id,
            order_by: m.id,
            select: %{
              channel: coalesce(c.name, "direct message"),
              following: m.following,
              muted: m.muted,
              notification_level: m.notification_level
            }
          )
        ),
      reactions:
        Repo.all(
          from(r in Reaction,
            where: r.user_id == ^id,
            order_by: r.id,
            select: %{message_id: r.message_id, emoji: r.emoji}
          )
        )
    }
  end

  @doc """
  Removes what's personal of `user`'s chat, for account deletion: their
  memberships, read positions, mentions, reactions and flags. Their
  messages stay, under the anonymized account.
  """
  def delete_user(%User{id: id}) do
    for schema <- [Membership, ThreadMembership, Mention, Reaction, Flag],
        do: Repo.delete_all(from(r in schema, where: r.user_id == ^id))

    :ok
  end

  ## Live events

  @doc "Subscribes the caller to a channel's events."
  def subscribe(%Channel{id: id}), do: Phoenix.PubSub.subscribe(Firefly.PubSub, topic(id))

  @doc "Unsubscribes the caller from a channel's events."
  def unsubscribe(%Channel{id: id}), do: Phoenix.PubSub.unsubscribe(Firefly.PubSub, topic(id))

  @doc "Subscribes the caller to `user`'s chat events."
  def subscribe_user(%User{id: id}),
    do: Phoenix.PubSub.subscribe(Firefly.PubSub, user_topic(id))

  @doc "Subscribes the caller to staff's channel changes."
  def subscribe_channels, do: Phoenix.PubSub.subscribe(Firefly.PubSub, "chat:channels")

  @doc "The topic the web interface tracks presence in the channel on."
  def presence_topic(%Channel{id: id}), do: "chat:presence:#{id}"

  @doc """
  Tells the channel's other open pages that `user` is typing (in the
  thread with `thread_id`, or the channel's stream).
  """
  def typing(%Channel{id: id}, %User{} = user, thread_id \\ nil) do
    Phoenix.PubSub.broadcast_from(
      Firefly.PubSub,
      self(),
      topic(id),
      {:typing,
       %{channel_id: id, user_id: user.id, username: user.username, thread_id: thread_id}}
    )
  end

  defp topic(channel_id), do: "chat:channel:#{channel_id}"
  defp user_topic(user_id), do: "chat:user:#{user_id}"

  defp broadcast(channel_id, message),
    do: Phoenix.PubSub.broadcast(Firefly.PubSub, topic(channel_id), message)

  defp broadcast_user(user_id, message),
    do: Phoenix.PubSub.broadcast(Firefly.PubSub, user_topic(user_id), message)

  defp user_changed(user_id), do: broadcast_user(user_id, :channels_changed)

  defp channels_changed,
    do: Phoenix.PubSub.broadcast(Firefly.PubSub, "chat:channels", :channels_changed)
end
