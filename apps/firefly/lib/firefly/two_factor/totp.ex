defmodule Firefly.TwoFactor.Totp do
  @moduledoc """
  A user's authenticator app (see `Firefly.TwoFactor`): the TOTP
  secret and when its last code was used, so no code works twice.
  """
  use Ecto.Schema

  schema "user_totps" do
    field(:secret, :binary, redact: true)
    field(:last_used_at, :utc_datetime)
    belongs_to(:user, Firefly.Forums.User)

    timestamps(type: :utc_datetime)
  end
end
