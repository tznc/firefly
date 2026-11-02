defmodule FirestormWeb.Messages do
  @moduledoc """
  Private messages: conversations between two or more users, with an inbox.

  Conversations are separate from threads (their own tables), so the forum's
  lists, search, feeds and API never see them. Only active participants can
  read or reply (the `:view_conversation` policy); the starter or an admin
  among them can add people (`:add_participants`). Anyone may leave.

  Users who turned off "allow private messages" can't be messaged or added,
  except by admins. Each recipient gets a `"message"` notification and an
  email (see `FirestormWeb.Notifications.message_created/1`).
  """

  import Ecto.{Query, Changeset}

  alias FirestormWeb.{Forums, Notifications, RateLimit, Repo}

  alias FirestormWeb.Forums.{
    Conversation,
    ConversationParticipant,
    Message,
    Notification,
    SpamGuard,
    User
  }

  @max_participants 20

  @doc "How many people a conversation may have (the starter included)."
  def max_participants, do: @max_participants

  @doc "A changeset for the new-conversation form."
  def change_conversation(attrs \\ %{}), do: Conversation.new_changeset(%Conversation{}, attrs)

  @doc """
  Starts a conversation from `sender` to `attrs.recipients` (usernames,
  separated by commas or spaces, with or without `@`), with a title and a
  first message.
  """
  def start_conversation(%User{} = sender, attrs) do
    changeset =
      %Conversation{user_id: sender.id}
      |> Conversation.new_changeset(attrs)
      |> SpamGuard.validate_post(sender)

    {changeset, recipients} =
      with nil <- changeset.errors[:recipients],
           {:ok, users} <-
             resolve_users(get_change(changeset, :recipients), sender, MapSet.new([sender.id])) do
        {changeset, users}
      else
        {:error, message} -> {add_error(changeset, :recipients, message), []}
        _blank -> {changeset, []}
      end

    if changeset.valid? do
      insert_conversation(changeset, sender, recipients)
    else
      {:error, %{changeset | action: :insert}}
    end
  end

  defp insert_conversation(changeset, sender, recipients) do
    now = NaiveDateTime.utc_now()

    result =
      Repo.transact(fn ->
        conversation = changeset |> put_change(:last_message_at, now) |> Repo.insert!()
        message = Repo.insert!(new_message(conversation, sender, changeset.changes.body))
        :ok = FirestormWeb.Uploads.attach(message.body, sender, message)

        for user <- [sender | recipients] do
          read = if user.id == sender.id, do: message.id

          Repo.insert!(%ConversationParticipant{
            conversation_id: conversation.id,
            user_id: user.id,
            last_read_message_id: read
          })
        end

        {:ok, {conversation, message}}
      end)

    with {:ok, {conversation, message}} <- result do
      :ok = Notifications.message_created(message)
      {:ok, conversation}
    end
  end

  defp new_message(conversation, user, body),
    do: %Message{conversation_id: conversation.id, user_id: user.id, body: body}

  @doc "Replies to a conversation `user` is in."
  def reply(%Conversation{} = conversation, %User{} = user, attrs) do
    changeset =
      conversation
      |> new_message(user, nil)
      |> Message.changeset(attrs)
      |> SpamGuard.validate_post(user)

    cond do
      not participant?(conversation, user) ->
        {:error, :unauthorized}

      not changeset.valid? ->
        {:error, %{changeset | action: :insert}}

      true ->
        {:ok, message} =
          Repo.transact(fn ->
            message = Repo.insert!(changeset)
            :ok = FirestormWeb.Uploads.attach(message.body, user, message)

            Conversation
            |> where([c], c.id == ^conversation.id)
            |> Repo.update_all(set: [last_message_at: message.inserted_at])

            {:ok, message}
          end)

        mark_read(conversation, user)
        :ok = Notifications.message_created(message)
        broadcast(conversation, {:message_created, message})
        {:ok, message}
    end
  end

  @doc """
  Adds the users named in `input` to the conversation, as `actor` (see the
  `:add_participants` policy). People who left can't be added back (leaving
  sticks), and adds count towards `actor`'s `:message` rate limit.
  """
  def add_participants(%Conversation{} = conversation, %User{} = actor, input) do
    result =
      Repo.transact(fn ->
        # Locked, so concurrent adds can't together go over the maximum.
        Conversation |> where(id: ^conversation.id) |> lock("FOR UPDATE") |> Repo.one!()
        present = conversation |> active_participant_ids() |> MapSet.new()

        with {:ok, users} <- resolve_users(input, actor, present),
             :ok <- refuse_left(conversation, users),
             :ok <- rate_limit(actor) do
          Enum.each(users, &insert_participant(conversation, &1))
          {:ok, users}
        end
      end)

    with {:ok, users} <- result do
      :ok = Notifications.participants_added(conversation, actor, users)
      broadcast(conversation, {:participants_changed, conversation})
      {:ok, users}
    end
  end

  defp insert_participant(conversation, user),
    do: Repo.insert!(%ConversationParticipant{conversation_id: conversation.id, user_id: user.id})

  defp refuse_left(conversation, users) do
    ids = Enum.map(users, & &1.id)

    left =
      ConversationParticipant
      |> where([p], p.conversation_id == ^conversation.id and p.user_id in ^ids)
      |> where([p], not is_nil(p.left_at))
      |> select([p], p.user_id)
      |> Repo.all()

    case Enum.filter(users, &(&1.id in left)) do
      [] -> :ok
      gone -> {:error, "#{at(Enum.map(gone, & &1.username))} left this conversation"}
    end
  end

  defp rate_limit(actor) do
    case RateLimit.check_message(actor) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, RateLimit.message()}
    end
  end

  # Resolves usernames to users who may join a conversation started or
  # extended by `actor`, other than those in `present` (user ids).
  defp resolve_users(input, actor, present) do
    names = parse_usernames(input)
    found = Forums.users_by_username(names)
    unknown = Enum.reject(names, &Map.has_key?(found, &1))
    users = names |> Enum.map(&found[&1]) |> Enum.reject(&(is_nil(&1) or &1.id in present))
    closed = closed_to(users, actor)

    cond do
      unknown != [] ->
        {:error, "no such user: #{at(unknown)}"}

      users == [] ->
        {:error, "add at least one other person"}

      MapSet.size(present) + length(users) > @max_participants ->
        {:error, "a conversation can have at most #{@max_participants} people"}

      closed != [] ->
        {:error, "#{at(Enum.map(closed, & &1.username))} doesn't accept private messages"}

      true ->
        {:ok, users}
    end
  end

  defp parse_usernames(nil), do: []

  defp parse_usernames(input) do
    input
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&(&1 |> String.trim_leading("@") |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Admins may message anyone.
  defp closed_to(users, actor) do
    if Forums.admin?(actor), do: [], else: Enum.reject(users, & &1.allow_private_messages)
  end

  defp at(names), do: Enum.map_join(names, ", ", &"@#{&1}")

  @doc "Leaves a conversation: it's gone from the inbox, with its notifications."
  def leave(%Conversation{} = conversation, %User{} = user) do
    ConversationParticipant
    |> where([p], p.conversation_id == ^conversation.id and p.user_id == ^user.id)
    |> Repo.update_all(set: [left_at: DateTime.utc_now(:second)])

    Notification
    |> where([n], n.conversation_id == ^conversation.id and n.user_id == ^user.id)
    |> Repo.delete_all()

    Forums.notifications_changed(user.id)
    broadcast(conversation, {:participants_changed, conversation})
    :ok
  end

  @doc "Whether `user` is in the conversation (and hasn't left)."
  def participant?(%Conversation{id: id}, %User{id: user_id}) do
    ConversationParticipant
    |> where([p], p.conversation_id == ^id and p.user_id == ^user_id and is_nil(p.left_at))
    |> Repo.exists?()
  end

  def participant?(_conversation, nil), do: false

  defp active_participant_ids(%Conversation{id: id}) do
    ConversationParticipant
    |> where([p], p.conversation_id == ^id and is_nil(p.left_at))
    |> select([p], p.user_id)
    |> Repo.all()
  end

  @doc "The users in a conversation who haven't left, by username."
  def participants(%Conversation{id: id}) do
    User
    |> join(:inner, [u], p in ConversationParticipant,
      on: p.user_id == u.id and p.conversation_id == ^id and is_nil(p.left_at)
    )
    |> order_by([u], asc: u.username)
    |> Repo.all()
  end

  @doc "Gets a conversation by id, or nil. Check `:view_conversation` before showing it."
  def get_conversation(id), do: Repo.get(Conversation, id)

  @doc "A conversation's messages, oldest first, with their authors."
  def messages(%Conversation{id: id}) do
    Message
    |> where([m], m.conversation_id == ^id)
    |> order_by(asc: :id)
    |> preload(:user)
    |> Repo.all()
  end

  @doc "A conversation's first message."
  def first_message(%Conversation{id: id}),
    do: Message |> where([m], m.conversation_id == ^id) |> first(:id) |> Repo.one()

  @doc "A conversation's newest message."
  def latest_message(%Conversation{id: id}),
    do: Message |> where([m], m.conversation_id == ^id) |> last(:id) |> Repo.one()

  @doc """
  The conversations `user` is in, most recently active first, with
  `unread_count` and active participants (paginated).
  """
  def inbox(%User{} = user, page) do
    conversations =
      Conversation
      |> join(:inner, [c], p in ConversationParticipant,
        on: p.conversation_id == c.id and p.user_id == ^user.id and is_nil(p.left_at)
      )
      |> order_by([c], desc: c.last_message_at, desc: c.id)
      |> preload(
        participants:
          ^from(p in ConversationParticipant, where: is_nil(p.left_at), preload: :user)
      )
      |> Repo.paginate(page: page)

    unread = unread_counts(user)

    entries =
      Enum.map(conversations.entries, &%{&1 | unread_count: Map.get(unread, &1.id, 0)})

    %{conversations | entries: entries}
  end

  @doc "How many conversations have messages `user` hasn't read."
  def unread_conversation_count(%User{} = user), do: map_size(unread_counts(user))

  def unread_conversation_count(nil), do: 0

  # Conversation id => number of unread messages, for those with any.
  defp unread_counts(user) do
    Message
    |> join(:inner, [m], p in ConversationParticipant,
      on: p.conversation_id == m.conversation_id and p.user_id == ^user.id and is_nil(p.left_at)
    )
    |> where([m, p], m.id > coalesce(p.last_read_message_id, 0))
    |> group_by([m], m.conversation_id)
    |> select([m], {m.conversation_id, count(m.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Where `user` had read up to in the conversation (a message id), or nil."
  def last_read_message_id(%Conversation{id: id}, %User{id: user_id}) do
    ConversationParticipant
    |> where([p], p.conversation_id == ^id and p.user_id == ^user_id)
    |> select([p], p.last_read_message_id)
    |> Repo.one()
  end

  @doc """
  Marks the conversation read up to its newest message, and its
  notifications with it. The position only moves forward.
  """
  def mark_read(%Conversation{id: id}, %User{id: user_id}) do
    last_id =
      Message |> where([m], m.conversation_id == ^id) |> select([m], max(m.id)) |> Repo.one()

    {moved, _} =
      ConversationParticipant
      |> where([p], p.conversation_id == ^id and p.user_id == ^user_id)
      |> where([p], is_nil(p.last_read_message_id) or p.last_read_message_id < ^last_id)
      |> Repo.update_all(set: [last_read_message_id: last_id])

    {read, _} =
      Notification
      |> where([n], n.user_id == ^user_id and n.conversation_id == ^id and is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])

    # The unread badges (messages and notifications) follow this topic.
    if moved + read > 0, do: Forums.notifications_changed(user_id)
    :ok
  end

  ## Live events
  #
  # "conversation:<id>" - {:message_created, message} and
  # {:participants_changed, conversation}

  @doc "Subscribes the caller to a conversation's events."
  def subscribe(%Conversation{id: id}),
    do: Phoenix.PubSub.subscribe(FirestormWeb.PubSub, "conversation:#{id}")

  defp broadcast(%Conversation{id: id}, message),
    do: Phoenix.PubSub.broadcast(FirestormWeb.PubSub, "conversation:#{id}", message)
end
