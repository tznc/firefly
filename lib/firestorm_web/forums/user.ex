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
    field(:confirmed_at, :utc_datetime)
    field(:email_notifications, :boolean, default: true)
    field(:allow_private_messages, :boolean, default: true)
    field(:bio, :string)
    field(:website, :string)
    field(:location, :string)
    field(:theme, :string, default: "system")
    field(:reply_level, :string, default: "tracking")
    field(:new_thread_level, :string, default: "watching")
    field(:hide_profile_activity, :boolean, default: false)
    field(:hide_from_directory, :boolean, default: false)
    field(:deleted_at, :utc_datetime)
    field(:silenced_until, :utc_datetime)
    field(:silence_reason, :string)
    field(:suspended_until, :utc_datetime)
    field(:suspend_reason, :string)

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

  @doc "The themes a user can pick (`system` follows the browser)."
  def themes, do: ~w(system light dark)

  @doc "The notification levels a user can pick for threads they reply to."
  def reply_levels, do: ~w(tracking normal)

  @doc "The notification levels a user can pick for threads they start."
  def new_thread_levels, do: ~w(watching tracking)

  @doc "Interface, notification, messaging and privacy preferences (see /settings)."
  def preferences_changeset(%__MODULE__{} = user, attrs) do
    user
    |> cast(attrs, [
      :email_notifications,
      :allow_private_messages,
      :theme,
      :reply_level,
      :new_thread_level,
      :hide_profile_activity,
      :hide_from_directory
    ])
    |> validate_required([:theme, :reply_level, :new_thread_level])
    |> validate_inclusion(:theme, themes())
    |> validate_inclusion(:reply_level, reply_levels())
    |> validate_inclusion(:new_thread_level, new_thread_levels())
  end

  @doc "Whether the account was deleted (it remains, anonymized, as its posts' author)."
  def deleted?(%__MODULE__{deleted_at: deleted_at}), do: not is_nil(deleted_at)

  @doc "Whether the user is silenced now: they can read, but not post, message or like."
  def silenced?(%__MODULE__{silenced_until: until}), do: in_force?(until)

  @doc "Whether the user is suspended now: they can't log in."
  def suspended?(%__MODULE__{suspended_until: until}), do: in_force?(until)

  defp in_force?(nil), do: false
  defp in_force?(until), do: DateTime.after?(until, DateTime.utc_now())

  @doc "Whether the user has confirmed their email address."
  def confirmed?(%__MODULE__{confirmed_at: confirmed_at}), do: not is_nil(confirmed_at)

  @doc "Sets a new password (password reset)."
  def password_changeset(%__MODULE__{} = user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    |> validate_confirmation(:password, message: "does not match password")
    |> put_password_hash()
  end

  @doc "Marks the user's email address as confirmed."
  def confirm_changeset(%__MODULE__{} = user) do
    change(user, confirmed_at: DateTime.utc_now(:second))
  end

  @doc """
  Profile edits: account fields, plus a short markdown bio, a website and a
  location shown on the profile. Changing the email address requires
  confirming it again.
  """
  def update_changeset(%__MODULE__{} = user, attrs) do
    changeset =
      user
      |> changeset(attrs)
      |> cast(attrs, [:bio, :website, :location])
      |> update_change(:website, &String.trim/1)
      |> validate_length(:name, max: 100)
      |> validate_length(:bio, max: 1_000)
      |> validate_length(:location, max: 100)
      |> validate_length(:website, max: 200)
      |> validate_change(:website, &validate_website/2)

    if get_change(changeset, :email),
      do: put_change(changeset, :confirmed_at, nil),
      else: changeset
  end

  # Only web links: a javascript: or data: URL on a profile would be an XSS.
  defp validate_website(:website, url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        []

      _ ->
        [website: "must be a web address starting with http:// or https://"]
    end
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
