defmodule Firefly.Chat.Policy do
  @moduledoc """
  Authorization rules for chat (see `Bodyguard.Policy`; ask through
  `Firefly.Chat.can?/3`):

    * `:use_chat` - while the `chat_enabled` site setting is on, admins and
      members of a group the `chat_allowed_groups` setting names
    * `:create_direct_message` - chat users in a group the
      `direct_message_enabled_groups` setting names, and admins
    * `:view_channel` (params: the channel) - chat users: a direct message
      channel's members only (admins included); a category channel, anyone
      who may read its category (see `Firefly.Discussion.Policy`), or
      everyone when it has none
    * `:post_message` (the channel) - those who may view it, while it's
      `open`; staff also while it's `closed`; nobody in a `read_only` or
      `archived` one
    * `:edit_message` (the message) - its author, while it isn't deleted
      and they may still post in its channel
    * `:delete_message` (the message) - its author (while they may view
      the channel) and admins, unless it's deleted already
    * `:restore_message` (the message) - admins; its author if they
      deleted it themselves
    * `:react` (the message) - those who may post in its channel, unless
      it's deleted
    * `:pin_message` (the message) - in a category channel admins; in a
      direct message its members. Not deleted messages
    * `:flag_message` (the message) - those who may view its channel, at
      `min_trust_to_flag`, on others' messages that aren't deleted
    * `:manage_channel` (create, edit, open, close and archive channels) -
      admins; also reviewing chat flags and removing members

  Being able to post doesn't mean posting now: `Firefly.Moderation.Posting`
  (penalties, read-only mode, confirmation, the chat rate limit) decides
  that.
  """

  @behaviour Bodyguard.Policy

  import Ecto.Query

  alias Firefly.{Accounts, Repo, SiteSettings, TrustLevels}
  alias Firefly.Accounts.User
  alias Firefly.Chat.{Channel, Membership, Message}
  alias Firefly.Discussion.Policy, as: DiscussionPolicy
  alias Firefly.Groups.{Role, RoleMembership}

  @impl true
  def authorize(_action, nil, _params), do: {:error, :unauthenticated}

  def authorize(:use_chat, %User{} = user, _params) do
    ok(
      SiteSettings.get("chat_enabled") and is_nil(user.deleted_at) and
        in_groups?(user, "chat_allowed_groups")
    )
  end

  def authorize(:create_direct_message, %User{} = user, _params) do
    with :ok <- authorize(:use_chat, user, nil),
         do: ok(in_groups?(user, "direct_message_enabled_groups"))
  end

  def authorize(:manage_channel, %User{} = user, _params), do: ok(Accounts.admin?(user))

  def authorize(:view_channel, %User{} = user, %Channel{} = channel) do
    with :ok <- authorize(:use_chat, user, nil), do: ok(viewable?(channel, user))
  end

  def authorize(:post_message, %User{} = user, %Channel{} = channel) do
    with :ok <- authorize(:view_channel, user, channel) do
      case channel.status do
        "open" -> :ok
        "closed" -> ok(Accounts.admin?(user))
        _read_only_or_archived -> {:error, :unauthorized}
      end
    end
  end

  def authorize(:edit_message, %User{id: id} = user, %Message{user_id: id} = message) do
    message = Repo.preload(message, :channel)

    if Message.deleted?(message),
      do: {:error, :unauthorized},
      else: authorize(:post_message, user, message.channel)
  end

  def authorize(:delete_message, %User{} = user, %Message{} = message) do
    message = Repo.preload(message, :channel)

    cond do
      Message.deleted?(message) -> {:error, :unauthorized}
      Accounts.admin?(user) -> :ok
      message.user_id == user.id -> authorize(:view_channel, user, message.channel)
      true -> {:error, :unauthorized}
    end
  end

  def authorize(:restore_message, %User{} = user, %Message{} = message) do
    cond do
      not Message.deleted?(message) -> {:error, :unauthorized}
      Accounts.admin?(user) -> :ok
      message.user_id == user.id and message.deleted_by_id == user.id -> :ok
      true -> {:error, :unauthorized}
    end
  end

  def authorize(:react, %User{} = user, %Message{} = message) do
    message = Repo.preload(message, :channel)

    if Message.deleted?(message),
      do: {:error, :unauthorized},
      else: authorize(:post_message, user, message.channel)
  end

  def authorize(:pin_message, %User{} = user, %Message{} = message) do
    message = Repo.preload(message, :channel)

    cond do
      Message.deleted?(message) -> {:error, :unauthorized}
      message.channel.kind == "direct" -> authorize(:view_channel, user, message.channel)
      true -> ok(Accounts.admin?(user))
    end
  end

  def authorize(:flag_message, %User{} = user, %Message{} = message) do
    message = Repo.preload(message, :channel)

    if Message.deleted?(message) or message.user_id == user.id or
         not TrustLevels.allowed?(user, "min_trust_to_flag"),
       do: {:error, :unauthorized},
       else: authorize(:view_channel, user, message.channel)
  end

  def authorize(_action, _user, _params), do: {:error, :unauthorized}

  defp ok(true), do: :ok
  defp ok(false), do: {:error, :unauthorized}

  defp viewable?(%Channel{kind: "direct", id: id}, user) do
    Repo.exists?(from(m in Membership, where: m.channel_id == ^id and m.user_id == ^user.id))
  end

  defp viewable?(%Channel{category_id: nil}, _user), do: true

  defp viewable?(%Channel{category_id: category_id}, user) do
    Accounts.admin?(user) or
      not Repo.exists?(
        where(DiscussionPolicy.hidden_category_ids(user), [c], c.id == ^category_id)
      )
  end

  @doc """
  Restricts a query of channels (the first binding) to the category
  channels `user` may view, as `:view_channel` does for one (direct
  message channels are left out).
  """
  def viewable_category_channels(query, %User{} = user) do
    query = where(query, [c], c.kind == "category")

    if Accounts.admin?(user),
      do: query,
      else:
        where(
          query,
          [c],
          is_nil(c.category_id) or
            c.category_id not in subquery(DiscussionPolicy.hidden_category_ids(user))
        )
  end

  @doc "Whether `user` is an admin or in a group the setting `key` names."
  def in_groups?(%User{} = user, key) do
    case group_names(SiteSettings.get(key)) do
      [] ->
        Accounts.admin?(user)

      names ->
        Accounts.admin?(user) or
          Repo.exists?(
            from(m in RoleMembership,
              join: r in Role,
              on: r.id == m.role_id,
              where: m.user_id == ^user.id and r.name in ^names
            )
          )
    end
  end

  @doc "The group names in a list setting's value (`@` optional), lowercased."
  def group_names(names) when is_list(names),
    do: Enum.map(names, &(&1 |> String.trim_leading("@") |> String.downcase()))
end
