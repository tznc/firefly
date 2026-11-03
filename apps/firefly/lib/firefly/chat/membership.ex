defmodule Firefly.Chat.Membership do
  @moduledoc """
  A user in a chat channel. `following`: the channel is in their list
  (false once they leave it); `muted`: its unread messages don't count;
  `notification_level`: `"always"` (every message), `"mention"` (only
  messages mentioning them) or `"never"`. `last_read_message_id` is how
  far they've read.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Firefly.Accounts.User
  alias Firefly.Chat.Channel

  @levels ~w(always mention never)

  schema "chat_memberships" do
    field(:following, :boolean, default: true)
    field(:muted, :boolean, default: false)
    field(:notification_level, :string, default: "mention")
    field(:last_read_message_id, :integer)
    belongs_to(:channel, Channel)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec)
  end

  def levels, do: @levels

  @doc "The member's own settings."
  def settings_changeset(%__MODULE__{} = membership, attrs) do
    membership
    |> cast(attrs, [:muted, :notification_level])
    |> validate_inclusion(:notification_level, @levels)
  end
end
