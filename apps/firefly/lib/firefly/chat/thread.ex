defmodule Firefly.Chat.Thread do
  @moduledoc """
  A thread of replies to a chat message (its `original_message`), read in
  its own pane: the replies stay out of the channel's stream.
  """

  use Ecto.Schema

  alias Firefly.Chat.{Channel, Message}

  schema "chat_threads" do
    field(:last_reply_at, :naive_datetime_usec)
    belongs_to(:channel, Channel)
    belongs_to(:original_message, Message)

    timestamps(type: :naive_datetime_usec)
  end
end
