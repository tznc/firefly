defmodule Firefly.Accounts do
  @moduledoc """
  The Accounts context: members' accounts and everything about getting
  into one.

  This module is the context's entry point for users themselves (lookup,
  registration, profile updates, password login, the admin check). Its
  other public modules are:

    * `Firefly.Accounts.User`, `UserIdentity`, `UserIgnore` - the schemas
    * `Firefly.Accounts.Auth` - social logins and single sign-on (OIDC,
      SAML, LDAP, DiscourseConnect) and their Ueberauth strategies, and
      `Auth.DiscourseConnectProvider` (other sites logging in through ours)
    * `Firefly.Accounts.TwoFactor`, `Passkeys`, `WebAuthn` - second factors
    * `Firefly.Accounts.MagicLinks`, `PasswordReset`, `EmailConfirmation`
    * `Firefly.Accounts.AccountDeletion`, `AccountExport`
    * `Firefly.Accounts.Ignores`, `Profiles`, `Visits`, `UserSessions`
    * `Firefly.Accounts.Invites` (with the schemas `Invite`,
      `InviteRedemption`) - invitations to join

  Other contexts and the web interface use only these (see `Firefly`).
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [
      User,
      Auth,
      Auth.DiscourseConnect,
      Auth.SAML,
      Auth.LDAP,
      Auth.DiscourseConnectProvider,
      Auth.DiscourseConnectClient,
      TwoFactor,
      Passkeys,
      WebAuthn,
      MagicLinks,
      PasswordReset,
      EmailConfirmation,
      AccountDeletion,
      AccountExport,
      Ignores,
      Profiles,
      Visits,
      UserSessions,
      Invites,
      Invite,
      InviteRedemption
    ]

  import Ecto.Query, warn: false

  alias Firefly.{Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Plugins.Events

  @doc """
  Returns the list of users.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user, or nil if it does not exist.
  """
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Gets a single user by username. Maybe.
  """
  def get_user_by_username(username), do: Repo.get_by(User, %{username: username})

  @doc """
  The users with the given usernames (any case), as a map from each given
  name to its user. Deleted accounts can't be mentioned or messaged.
  """
  def users_by_username([]), do: %{}

  def users_by_username(names) do
    by_lower =
      User
      |> where([u], fragment("lower(?)", u.username) in ^Enum.map(names, &String.downcase/1))
      |> where([u], is_nil(u.deleted_at))
      |> order_by(asc: :id)
      |> Repo.all()
      |> Enum.group_by(&String.downcase(&1.username))

    # Usernames are only unique case-sensitively, so `@alice` could fit both
    # "Alice" and "alice": the exact match wins, else the oldest account.
    for name <- names, users = by_lower[String.downcase(name)], into: %{} do
      {name, Enum.find(users, hd(users), &(&1.username == name))}
    end
  end

  @doc "Up to `limit` users whose username starts with `prefix` (any case), shortest first."
  def search_usernames(prefix, limit \\ 6) do
    pattern = String.replace(String.downcase(prefix), ~r/[\\%_]/, "\\\\\\0") <> "%"

    # `lower(username) LIKE` rather than ILIKE, so it can use the index.
    User
    |> where([u], like(fragment("lower(?)", u.username), ^pattern) and is_nil(u.deleted_at))
    |> order_by([u], asc: fragment("length(?)", u.username), asc: u.username)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets a single user by api_token. Maybe.
  """
  def get_user_by_api_token(api_token), do: Repo.get_by(User, %{api_token: api_token})

  @doc """
  Gets a single user by email address. Maybe.
  """
  def get_user_by_email(email), do: Repo.get_by(User, %{email: email})

  @doc """
  Creates a user.

  ## Examples

      iex> create_user(%{field: value})
      {:ok, %User{}}

      iex> create_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user(attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put(:api_token, generate_api_token())

    # Accounts created directly (by admins, scripts) are trusted: confirmed,
    # and past the new-user stage (see Firefly.TrustLevels).
    %User{confirmed_at: DateTime.utc_now(:second), trust_level: Map.get(attrs, :trust_level, 1)}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a user with a username, email and password.

      iex> register_user(%{username: "ada", email: "ada@example.com", password: "s3cret-password"})
      {:ok, %User{}}
  """
  def register_user(attrs) do
    # Unconfirmed until they follow the emailed link (see EmailConfirmation).
    # Whether that's needed to post is the `require_email_confirmation`
    # setting's job (see `Firefly.Moderation.Posting`): `confirmed_at` only ever
    # means the address was proven.
    if registration_open?(),
      do: insert_registration(attrs, nil),
      else: {:error, :registration_closed}
  end

  @doc """
  `register_user/1` for someone redeeming an invite (see
  `Firefly.Accounts.Invites.register/2`, which checks registrations are
  allowed): `confirmed?` when the invite was emailed to the address.
  """
  def register_invited_user(attrs, confirmed?),
    do: insert_registration(attrs, if(confirmed?, do: DateTime.utc_now(:second)))

  defp insert_registration(attrs, confirmed_at) do
    %User{api_token: generate_api_token(), confirmed_at: confirmed_at}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
    |> tap_ok(&Events.emit("user_registered", %{user: %{id: &1.id, username: &1.username}}))
  end

  @doc """
  Whether anyone may create an account: the `allow_registrations` site
  setting is on and `invite_only` is off (invited people may join while
  only `allow_registrations` is on; see `Firefly.Accounts.Invites`).
  """
  def registration_open?,
    do: SiteSettings.get("allow_registrations") and not SiteSettings.get("invite_only")

  @doc "A changeset for the registration form."
  def change_registration(%User{} = user \\ %User{}, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  @doc """
  Updates a user.

  ## Examples

      iex> update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  @doc "Users with a password whose email matches (case-insensitively)."
  def list_password_users_by_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    User
    |> where([u], fragment("lower(?)", u.email) == ^email and not is_nil(u.password_hash))
    |> Repo.all()
  end

  @doc """
  Sets a new password from a reset link. Following the emailed link proves the
  address, so it also confirms the email.
  """
  def reset_user_password(%User{} = user, attrs) do
    changeset = User.password_changeset(user, attrs)

    changeset =
      if User.confirmed?(user),
        do: changeset,
        else: Ecto.Changeset.put_change(changeset, :confirmed_at, DateTime.utc_now(:second))

    Repo.update(changeset)
  end

  def update_preferences(%User{} = user, attrs) do
    user |> User.preferences_changeset(attrs) |> Repo.update()
  end

  @doc "Marks the user's email address as confirmed."
  def confirm_user(%User{} = user) do
    if User.confirmed?(user),
      do: {:ok, user},
      else: user |> User.confirm_changeset() |> Repo.update()
  end

  @doc """
  Deletes a User.

  ## Examples

      iex> delete_user(user)
      {:ok, %User{}}

      iex> delete_user(user)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{source: %User{}}

  """
  def change_user(%User{} = user) do
    User.changeset(user, %{})
  end

  @doc """
  Logs in with a username and password. Unknown usernames and accounts
  without a password (social logins) fail the same way as a wrong
  password.
  """
  def authenticate_by_password(username, password)
      when is_binary(username) and is_binary(password) do
    case get_user_by_username(username) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        if Bcrypt.verify_pass(password, hash), do: {:ok, user}, else: login_error()

      _ ->
        Bcrypt.no_user_verify()
        login_error()
    end
  end

  def authenticate_by_password(_username, _password), do: login_error()

  defp login_error, do: {:error, "No user found with that username or password"}

  @doc "When `user` last had a page open (see `Firefly.Accounts.Visits`), or nil."
  def user_last_seen(%User{last_seen_at: at}), do: at

  defp generate_api_token(), do: Ecto.UUID.generate()

  def admin?(%User{} = user) do
    user =
      user
      |> Repo.preload(:roles)

    user.roles
    |> Enum.any?(fn role ->
      role.name == "admin"
    end)
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(result, _fun), do: result
end
