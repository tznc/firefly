defmodule Firefly.Forums.RoleMembership do
  @moduledoc """
  Schema for forum role (group) memberships. An `owner` manages the
  group's members (see `Firefly.Groups`); `notification_level` is how
  the member hears about messages to the group's inbox: `watching` (every
  message, emailed), `tracking` (every message), `normal` (new
  conversations only) or `muted`.
  """

  use Ecto.Schema
  import Ecto.Changeset, warn: false
  alias Firefly.Forums.{Role, User}

  @levels ~w(watching tracking normal muted)

  schema "forums_role_memberships" do
    field(:owner, :boolean, default: false)
    field(:notification_level, :string, default: "watching")
    belongs_to(:role, Role)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec)
  end

  def levels, do: @levels

  def changeset(%__MODULE__{} = role_membership, attrs \\ %{}) do
    role_membership
    |> cast(attrs, [:user_id, :role_id])
    |> validate_required([:user_id, :role_id])
    |> unique_constraint([:role_id, :user_id])
  end
end
