defmodule Firefly.Security.Ban do
  @moduledoc """
  A banned address (see `Firefly.Security.Jail`): `ip` is an address, an
  IPv6 /64 (`"2001:db8:1:2::/64"`) or, for staff bans, any range. `jail`
  is the signal group that banned it (`"manual"` for staff), `offences` how
  many times it was banned (each ban lasts longer), `banned_until` when the
  current one ends (nil: never). The row stays after the ban ends, to
  remember the offences, until the `ip_retention_days` setting has passed.
  """

  use Ecto.Schema

  alias Firefly.Accounts.User

  schema "bans" do
    field(:ip, :string)
    field(:jail, :string)
    field(:reason, :string)
    field(:offences, :integer, default: 1)
    field(:banned_until, :utc_datetime)
    belongs_to(:created_by, User)

    timestamps(type: :utc_datetime)
  end

  @doc "Whether the ban is in force at `now`."
  def active?(%__MODULE__{banned_until: nil}, _now), do: true
  def active?(%__MODULE__{banned_until: until}, now), do: DateTime.compare(until, now) == :gt
end
