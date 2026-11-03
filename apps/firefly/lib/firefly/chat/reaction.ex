defmodule Firefly.Chat.Reaction do
  @moduledoc """
  An emoji reaction to a chat message: a standard emoji (the character) or
  a custom one (`:name:`, see `Firefly.Rendering.Emoji`). One per user per
  emoji per message.
  """

  use Ecto.Schema

  alias Firefly.Accounts.User
  alias Firefly.Chat.Message

  schema "chat_reactions" do
    field(:emoji, :string)
    belongs_to(:message, Message)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
