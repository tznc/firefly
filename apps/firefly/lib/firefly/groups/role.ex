defmodule Firefly.Groups.Role do
  @moduledoc """
  Schema for forum roles. Roles double as groups: "admin" makes a user
  staff, and any role can be given access to restricted categories (see
  `Firefly.Discussion.Policy`). Admins manage them at `/staff/groups`.

  Group settings (see `Firefly.Groups`):

    * `visibility` - who sees the group, its page and members: `public`
      (everyone), `members` (its members) or `staff`
    * `membership` - how people join: `closed` (owners and staff add
      them), `open` (anyone joins), `request` (anyone asks; owners
      approve) or `invite` (owners invite; the invitee accepts)
    * `mentionable` - who may @mention it (notifying its members), and
      `messageable` - who may message its inbox: `nobody` (staff only),
      `owners`, `members` or `everyone`
    * `description` - the About tab

  The "admin" and "moderator" groups stay closed and staff-only: their
  members are staff (see `staff?/1`).
  The trust level groups (`trust_level_0` to `trust_level_4`, see
  `Firefly.TrustLevels`) stay closed: their members follow their
  trust level.
  """

  use Ecto.Schema
  use Firefly.Changeset
  alias Firefly.Accounts.User
  alias Firefly.Groups.RoleMembership

  @visibilities ~w(public members staff)
  @memberships ~w(closed open request invite)
  @levels ~w(nobody owners members everyone)

  schema "forums_roles" do
    field(:name, :string)
    field(:description, :string)
    field(:visibility, :string, default: "staff")
    field(:membership, :string, default: "closed")
    field(:mentionable, :string, default: "nobody")
    field(:messageable, :string, default: "nobody")
    has_many(:role_memberships, RoleMembership)
    many_to_many(:users, User, join_through: RoleMembership)

    timestamps(type: :naive_datetime_usec)
  end

  def visibilities, do: @visibilities
  def memberships, do: @memberships
  def levels, do: @levels

  def changeset(%__MODULE__{} = role, attrs \\ %{}) do
    role
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 40)
    |> unique_constraint(:name)
    |> unique_constraint(:name, name: :forums_roles_lower_name_index)
  end

  @doc "A group's settings (admins)."
  def settings_changeset(%__MODULE__{} = role, attrs) do
    role
    |> cast(attrs, [:description, :visibility, :membership, :mentionable, :messageable])
    |> validate_length(:description, max: 2_000)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_inclusion(:membership, @memberships)
    |> validate_inclusion(:mentionable, @levels)
    |> validate_inclusion(:messageable, @levels)
    |> validate_staff_group()
  end

  @doc "The About text, which owners edit too."
  def description_changeset(%__MODULE__{} = role, attrs) do
    role
    |> cast(attrs, [:description])
    |> validate_length(:description, max: 2_000)
  end

  defp validate_staff_group(%{data: %{name: name}} = changeset)
       when name in ~w(admin moderator) do
    changeset
    |> validate_inclusion(:membership, ["closed"], message: "must be closed for a staff group")
    |> validate_inclusion(:visibility, ["staff"], message: "must be staff for a staff group")
  end

  defp validate_staff_group(%{data: %{name: name}} = changeset) do
    if automatic?(%__MODULE__{name: name}),
      do:
        validate_inclusion(changeset, :membership, ["closed"],
          message: "must be closed for a trust level group"
        ),
      else: changeset
  end

  @doc "Whether the group is a staff group (\"admin\" or \"moderator\")."
  def staff?(%__MODULE__{name: name}), do: name in ~w(admin moderator)

  @doc "Whether the group is a trust level's, whose members are set automatically."
  def automatic?(%__MODULE__{name: name}), do: Firefly.TrustLevels.group?(name)
end
