defmodule Firefly.AI.Translation do
  @moduledoc """
  A cached translation of a post or a chat message into one language (see
  `Firefly.AI.Translations`), with the hash of the text it translated.
  """
  use Ecto.Schema

  schema "ai_translations" do
    belongs_to(:post, Firefly.Discussion.Post)
    belongs_to(:chat_message, Firefly.Chat.Message)
    field(:language, :string)
    field(:source_hash, :binary)
    field(:content, :string)

    timestamps(type: :naive_datetime_usec)
  end
end
