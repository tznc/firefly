defmodule FirestormWeb.Forums.Conversation do
  @moduledoc """
  A private conversation (personal or group message) between participants.
  Kept apart from threads so nothing public can show it. `user` started it;
  `last_message_at` orders the inbox. `recipients` and `body` are only used
  by the new-conversation form.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FirestormWeb.Forums.{ConversationParticipant, Message, User}

  @max_title 200

  schema "forums_conversations" do
    field(:title, :string)
    field(:last_message_at, :naive_datetime_usec)
    field(:recipients, :string, virtual: true)
    field(:body, :string, virtual: true)
    field(:unread_count, :integer, virtual: true, default: 0)
    belongs_to(:user, User)
    has_many(:participants, ConversationParticipant)
    has_many(:messages, Message, preload_order: [asc: :id])

    timestamps(type: :naive_datetime_usec)
  end

  @doc "A new conversation: who it's for, its title and its first message."
  def new_changeset(%__MODULE__{} = conversation, attrs) do
    conversation
    |> cast(attrs, [:recipients, :title, :body])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:recipients, :title, :body])
    |> validate_length(:title, max: @max_title)
  end
end
