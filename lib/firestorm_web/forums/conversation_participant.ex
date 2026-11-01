defmodule FirestormWeb.Forums.ConversationParticipant do
  @moduledoc """
  A user in a conversation. `last_read_message_id` is how far they've read;
  `left_at` is set when they leave (they no longer see or hear about it,
  unless someone adds them back).
  """

  use Ecto.Schema

  alias FirestormWeb.Forums.{Conversation, User}

  schema "forums_conversation_participants" do
    field(:last_read_message_id, :integer)
    field(:left_at, :utc_datetime)
    belongs_to(:conversation, Conversation)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec)
  end
end
