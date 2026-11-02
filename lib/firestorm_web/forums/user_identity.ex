defmodule FirestormWeb.Forums.UserIdentity do
  @moduledoc """
  A user's account at a login provider (see `FirestormWeb.Auth`): the
  provider's name, its immutable id for the account (`uid`) and what it
  told us (`info`: nickname, name, email), shown in the user's settings.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias FirestormWeb.Forums.User

  schema "user_identities" do
    field(:provider, :string)
    field(:uid, :string)
    field(:info, :map, default: %{})
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = identity, attrs) do
    identity
    |> cast(attrs, [:provider, :uid, :info, :user_id])
    |> validate_required([:provider, :uid, :user_id])
    |> unique_constraint([:provider, :uid], message: "is linked to another account")
    |> unique_constraint([:user_id, :provider],
      message: "can't be added: you already connected one"
    )
  end
end
