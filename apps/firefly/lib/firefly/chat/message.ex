defmodule Firefly.Chat.Message do
  @moduledoc """
  A chat message: Markdown, like a post. `thread_id` puts it in a thread
  (a thread's original message has it too); `in_reply_to_id` quotes the
  message it answers. `edited_at` is set by edits (the earlier bodies are
  `Firefly.Chat.MessageRevision`s); `deleted_at` and `deleted_by_id` by a
  soft delete, which the author or staff can undo.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Firefly.Accounts.User
  alias Firefly.Chat.{Channel, Thread}

  @max_length 6000

  schema "chat_messages" do
    field(:body, :string)
    field(:edited_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)
    belongs_to(:channel, Channel)
    belongs_to(:user, User)
    belongs_to(:thread, Thread)
    belongs_to(:in_reply_to, __MODULE__)
    belongs_to(:deleted_by, User)

    # How many replies its thread has (for a thread's original message),
    # when loaded for display.
    field(:reply_count, :integer, virtual: true, default: 0)

    timestamps(type: :naive_datetime_usec)
  end

  @doc "The longest message allowed, in characters."
  def max_length, do: @max_length

  def changeset(%__MODULE__{} = message, attrs) do
    message
    |> cast(attrs, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: @max_length)
  end

  def deleted?(%__MODULE__{deleted_at: deleted_at}), do: not is_nil(deleted_at)
end
