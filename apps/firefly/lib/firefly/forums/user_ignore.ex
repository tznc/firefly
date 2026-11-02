defmodule Firefly.Forums.UserIgnore do
  @moduledoc """
  One member muting or ignoring another (see `Firefly.Ignores`).
  `level` is `"mute"` or `"ignore"`; `expires_at` (nil: never) ends it.
  """

  use Ecto.Schema

  alias Firefly.Forums.User

  schema "user_ignores" do
    field(:level, :string)
    field(:expires_at, :utc_datetime)
    belongs_to(:user, User)
    belongs_to(:ignored_user, User)

    timestamps(type: :naive_datetime_usec)
  end
end
