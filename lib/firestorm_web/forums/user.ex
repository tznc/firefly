defmodule FirestormWeb.Forums.User do
  @moduledoc """
  Schema for forum users.
  """

  use Ecto.Schema

  import Ecto.Changeset, warn: false
  alias FirestormWeb.Forums.{Post, RoleMembership, Role}

  schema "forums_users" do
    field(:email, :string)
    field(:name, :string)
    field(:username, :string)
    field(:password_hash, :string)
    field(:password, :string, virtual: true)
    field(:api_token, :string)
    field(:github_uid, :string)

    has_many(:posts, Post)
    has_many(:role_memberships, RoleMembership)
    many_to_many(:roles, Role, join_through: RoleMembership, on_replace: :delete)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = user, attrs \\ %{}) do
    user
    |> cast(attrs, [:username, :email, :name, :api_token])
    |> validate_required([:username, :name, :api_token])
    |> unique_constraint(:username)
  end

  @doc "Links a user to a GitHub account (by GitHub's immutable user id)."
  def github_changeset(%__MODULE__{} = user, attrs) do
    user
    |> changeset(attrs)
    |> cast(attrs, [:github_uid])
    |> validate_required([:github_uid])
    |> unique_constraint(:github_uid)
  end

  def admin_changeset(%__MODULE__{} = user, attrs \\ %{}) do
    user
    |> changeset(attrs)
    |> add_roles(attrs)
  end

  @doc """
  Registration with a username, email and password. The display name defaults
  to the username.
  """
  def registration_changeset(%__MODULE__{} = user, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    attrs = Map.put_new(attrs, "name", attrs["username"])

    user
    |> changeset(attrs)
    |> cast(attrs, [:password])
    |> validate_required([:email, :password])
    |> validate_format(:username, ~r/^[A-Za-z0-9_-]+$/,
      message: "can only contain letters, numbers, - and _"
    )
    |> validate_length(:username, min: 2, max: 32)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> validate_length(:password, min: 8, max: 72)
    |> unsafe_validate_unique(:username, FirestormWeb.Repo)
    |> put_password_hash()
  end

  def add_roles(changeset, params) do
    import Ecto.Query

    if Map.get(params, :roles, []) != [] do
      ids = params[:roles]
      # FIXME: I don't love going out to the repo here
      roles = FirestormWeb.Repo.all(from(r in Role, where: r.id in ^ids))
      put_assoc(changeset, :roles, roles)
    else
      changeset
    end
  end

  @doc """
  The user's Gravatar, falling back to a generated identicon. Users without an
  email get an identicon derived from their username.
  """
  def avatar_url(%__MODULE__{email: email, username: username}, size \\ 256) do
    (email || "#{username}@users.firestorm.invalid")
    |> Exgravatar.gravatar_url(d: "identicon", s: size)
  end

  defp put_password_hash(changeset) do
    case changeset do
      %Ecto.Changeset{valid?: true, changes: %{password: pass}} ->
        changeset
        |> put_change(:password_hash, Bcrypt.hash_pwd_salt(pass))

      _ ->
        changeset
    end
  end
end
