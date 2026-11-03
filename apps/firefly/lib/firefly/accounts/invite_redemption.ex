defmodule Firefly.Accounts.InviteRedemption do
  @moduledoc "A member who joined (or used) an invite (see `Firefly.Accounts.Invites`)."
  use Ecto.Schema

  alias Firefly.Accounts.{Invite, User}

  schema "invite_redemptions" do
    belongs_to(:invite, Invite)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
