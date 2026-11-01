defmodule FirestormWeb.Forums.Role do
  @moduledoc """
  Schema for forum roles. Roles double as groups: "admin" makes a user
  staff, and any role can be given access to restricted categories (see
  `FirestormWeb.Forums.Policy`). Admins manage them at `/staff/groups`.
  """

  use Ecto.Schema
  import Ecto.Changeset, warn: false
  alias FirestormWeb.Forums.{User, RoleMembership}

  schema "forums_roles" do
    field(:name, :string)
    has_many(:role_memberships, RoleMembership)
    many_to_many(:users, User, join_through: RoleMembership)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = role, attrs \\ %{}) do
    role
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 40)
    |> unique_constraint(:name)
  end
end
