defmodule Firefly.Chat.MessageRevision do
  @moduledoc "A chat message's body before an edit, and who edited it."

  use Ecto.Schema

  alias Firefly.Accounts.User
  alias Firefly.Chat.Message

  schema "chat_message_revisions" do
    field(:body, :string)
    belongs_to(:message, Message)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
