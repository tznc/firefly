defmodule Firefly.Chat.Mention do
  @moduledoc "A user a chat message mentions, for their unread mention count."

  use Ecto.Schema

  alias Firefly.Accounts.User
  alias Firefly.Chat.Message

  schema "chat_mentions" do
    belongs_to(:message, Message)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
