defmodule FireflyWeb.Api.V1.ChatController do
  @moduledoc """
  Chat (see `Firefly.Chat`): the user's channels and the ones they may
  join, a channel's messages (newest first, paged backwards), sending,
  editing and deleting messages, and following channels. Off (`404`)
  while chat is off; only members who may chat get in.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Chat
  alias Firefly.Rendering.Markdown
  alias FireflyWeb.Api.{Pagination, Problem}
  alias FireflyWeb.Api.V1.UserJSON

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  @reads [:index, :browse, :messages]
  plug(:require_user)
  plug(:chat_available)
  plug(:require_scope, "read" when action in @reads)
  plug(:require_scope, "chat:write" when action not in @reads)

  def index(conn, _params) do
    user = current_user(conn)
    %{channels: channels, direct: direct} = Chat.my_channels(user)
    ok(conn, Enum.map(channels ++ direct, &listed(&1, user)))
  end

  def browse(conn, _params) do
    user = current_user(conn)

    ok(
      conn,
      for {channel, following?} <- Chat.browse_channels(user) do
        user |> channel_json(channel) |> Map.put(:following, following?)
      end
    )
  end

  @doc "A page of the channel's messages: the newest, or those before the cursor's."
  def messages(conn, %{"id" => id} = params) do
    user = current_user(conn)
    limit = Pagination.limit(params)

    with {:ok, channel} <- fetch(id, user),
         {:ok, before} <- before_id(params) do
      opts = if before, do: [before: before, limit: limit], else: [limit: limit]
      messages = Chat.messages(channel, user, opts)
      next = if length(messages) == limit, do: Pagination.before_cursor(hd(messages).id)

      json(conn, %{data: Enum.map(messages, &message/1), meta: %{limit: limit, next_cursor: next}})
    end
  end

  defp before_id(params) do
    case Pagination.before_id(params) do
      :invalid -> {:error, {400, "The cursor is invalid."}}
      before -> {:ok, before}
    end
  end

  @doc "`body`, and optionally `in_reply_to_id` or `thread_of` (a message to reply in the thread of)."
  def create(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, channel} <- fetch(id, user),
         {:ok, message} <-
           Chat.send_message(channel, user, Map.take(params, ~w(body in_reply_to_id thread_of))) do
      ok(conn, message(message), 201)
    end
  end

  def update(conn, %{"message_id" => id} = params) do
    user = current_user(conn)

    with {:ok, message} <- fetch_message(id, user),
         {:ok, message} <- Chat.edit_message(message, user, Map.take(params, ["body"])) do
      ok(conn, message(Chat.display(message)))
    end
  end

  def delete(conn, %{"message_id" => id}) do
    user = current_user(conn)

    with {:ok, message} <- fetch_message(id, user),
         {:ok, _message} <- Chat.delete_message(message, user) do
      no_content(conn)
    end
  end

  def follow(conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, channel} <- fetch(id, user) do
      result =
        cond do
          conn.method == "DELETE" -> Chat.unfollow(channel, user)
          channel.kind == "category" -> Chat.follow(channel, user)
          true -> :ok
        end

      with :ok <- result, do: no_content(conn)
    end
  end

  defp fetch(id, user) do
    with id when is_integer(id) <- int(id),
         %{} = channel <- Chat.get_channel(id),
         true <- Chat.can?(user, :view_channel, channel) do
      {:ok, channel}
    else
      _missing_or_hidden -> {:error, :not_found}
    end
  end

  defp fetch_message(id, user) do
    with id when is_integer(id) <- int(id),
         %{} = message <- Chat.get_message(id),
         {:ok, _channel} <- fetch(message.channel_id, user) do
      {:ok, message}
    else
      _missing_or_hidden -> {:error, :not_found}
    end
  end

  defp listed(entry, user) do
    user
    |> channel_json(entry.channel)
    |> Map.merge(%{unread: entry.unread, mentions: entry.mentions, muted: entry.membership.muted})
  end

  defp channel_json(user, channel) do
    %{
      id: channel.id,
      kind: channel.kind,
      title: Chat.title(channel, user),
      slug: channel.slug,
      description: channel.description,
      status: channel.status,
      category_id: channel.category_id,
      last_message_at: channel.last_message_at
    }
  end

  defp message(message) do
    deleted? = message.deleted_at != nil
    body = if deleted?, do: "", else: message.body

    %{
      id: message.id,
      channel_id: message.channel_id,
      body: body,
      body_html: Markdown.render(body),
      user: if(match?(%Firefly.Accounts.User{}, message.user), do: UserJSON.data(message.user)),
      thread_id: message.thread_id,
      in_reply_to_id: message.in_reply_to_id,
      reply_count: message.reply_count,
      deleted: deleted?,
      edited_at: message.edited_at,
      inserted_at: message.inserted_at
    }
  end

  defp chat_available(conn, _opts) do
    if Chat.enabled?() and Chat.can?(current_user(conn), :use_chat),
      do: conn,
      else: Problem.send(conn, 404, "Chat is off.")
  end
end
