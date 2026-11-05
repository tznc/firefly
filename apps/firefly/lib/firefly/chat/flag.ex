defmodule Firefly.Chat.Flag do
  @moduledoc """
  A flag on a chat message, for the staff review queue (see
  `Firefly.Moderation.Review`): a member's (`user_id`), or the system's
  for a watched word (no user), with a `reason` as post flags have (see
  `Firefly.Moderation.Flag`) and a review `status`: `"pending"`, then
  `"agreed"` (the message was deleted) or `"disagreed"`.
  """
  use Ecto.Schema
  use Firefly.Changeset

  alias Firefly.Accounts.User
  alias Firefly.Chat.Message
  alias Firefly.Moderation.Flag, as: PostFlag

  schema "chat_message_flags" do
    field(:reason, :string)
    field(:note, :string)
    field(:status, :string, default: "pending")
    field(:reviewed_at, :utc_datetime)
    belongs_to(:message, Message)
    belongs_to(:user, User)
    belongs_to(:reviewed_by, User)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = flag, attrs) do
    flag
    |> cast(attrs, [:reason, :note])
    |> update_change(:note, &String.trim/1)
    |> validate_required([:reason])
    |> validate_inclusion(:reason, PostFlag.reasons())
    |> validate_length(:note, max: 1000)
    |> unique_constraint([:message_id, :user_id], message: "you already flagged this message")
  end
end
