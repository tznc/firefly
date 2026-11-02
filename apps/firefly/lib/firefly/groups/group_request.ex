defmodule Firefly.Groups.GroupRequest do
  @moduledoc """
  A pending way into a group (see `Firefly.Groups`): a member's
  `"request"` to join, which an owner approves or denies, or an owner's
  `"invite"`, which the invitee accepts or declines.
  """
  use Ecto.Schema

  alias Firefly.Accounts.User
  alias Firefly.Groups.Role

  schema "group_requests" do
    field(:kind, :string)
    field(:message, :string)
    belongs_to(:role, Role)
    belongs_to(:user, User)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
