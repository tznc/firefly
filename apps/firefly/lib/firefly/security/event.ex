defmodule Firefly.Security.Event do
  @moduledoc """
  An entry in the security log (see `Firefly.Security`): what happened
  (`kind`), to which member's account (`user_id`; nil for events about an
  address alone, such as an IP ban), from which client (`ip`, `user_agent`)
  and its `details`. IP addresses are truncated after the
  `ip_retention_days` setting.
  """

  use Ecto.Schema

  alias Firefly.Accounts.User

  schema "security_events" do
    field(:kind, :string)
    field(:ip, :string)
    field(:user_agent, :string)
    field(:details, :map, default: %{})
    belongs_to(:user, User)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
