defmodule Firefly.Chat.ThreadMembership do
  @moduledoc """
  A user taking part in a chat thread (they started its message or replied
  in it): how far they've read it, for its unread count.
  """

  use Ecto.Schema

  alias Firefly.Accounts.User
  alias Firefly.Chat.Thread

  schema "chat_thread_memberships" do
    field(:last_read_message_id, :integer)
    belongs_to(:thread, Thread)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec)
  end
end
