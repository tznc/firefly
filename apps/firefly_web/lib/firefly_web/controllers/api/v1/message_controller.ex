defmodule FireflyWeb.Api.V1.MessageController do
  @moduledoc """
  Private messages: the inbox, a conversation with its messages (reading
  it marks it read), starting one (`recipients`: usernames) and replying.
  Only participants (and a group inbox's members) see a conversation.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Messaging
  alias Firefly.Moderation.Posting
  alias Firefly.Rendering.Markdown
  alias FireflyWeb.Api.Pagination
  alias FireflyWeb.Api.V1.UserJSON

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_user)
  plug(:require_scope, "read" when action in [:index, :show])
  plug(:require_scope, "messages:write" when action in [:create, :reply])

  def index(conn, params) do
    Pagination.render_page(
      conn,
      params,
      &Messaging.inbox(current_user(conn), &1),
      &conversation/1
    )
  end

  def show(conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, conversation} <- fetch(id, user) do
      Messaging.mark_read(conversation, user)

      conversation =
        conversation
        |> Firefly.Repo.preload(participants: :user)
        |> Map.put(:unread_count, 0)

      ok(
        conn,
        conversation
        |> conversation()
        |> Map.put(:messages, Enum.map(Messaging.messages(conversation), &message/1))
      )
    end
  end

  def create(conn, params) do
    user = current_user(conn)
    recipients = params["recipients"]
    recipients = if is_list(recipients), do: Enum.join(recipients, " "), else: recipients

    with :ok <- Posting.check(user, :new_conversation),
         {:ok, conversation} <-
           Messaging.start_conversation(user, %{
             "title" => params["title"],
             "body" => params["body"],
             "recipients" => recipients
           }) do
      ok(conn, %{id: conversation.id, title: conversation.title}, 201)
    end
  end

  def reply(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, conversation} <- fetch(id, user),
         :ok <- Posting.check(user),
         {:ok, message} <- Messaging.reply(conversation, user, %{body: params["body"]}) do
      ok(conn, message(Firefly.Repo.preload(message, :user)), 201)
    end
  end

  defp fetch(id, user) do
    with id when is_integer(id) <- int(id),
         %{} = conversation <- Messaging.get_conversation(id),
         :ok <- permit(user, :view_conversation, conversation) do
      {:ok, conversation}
    else
      _missing_or_not_theirs -> {:error, :not_found}
    end
  end

  defp conversation(conversation) do
    %{
      id: conversation.id,
      title: conversation.title,
      last_message_at: conversation.last_message_at,
      unread_count: conversation.unread_count,
      participants: Enum.map(conversation.participants, &UserJSON.data(&1.user))
    }
  end

  defp message(message) do
    %{
      id: message.id,
      body: message.body,
      body_html: Markdown.render(message.body),
      user: UserJSON.data(message.user),
      inserted_at: message.inserted_at
    }
  end
end
