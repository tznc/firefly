defmodule Firefly.Accounts.User do
  @moduledoc """
  Schema for forum users.
  """

  use Ecto.Schema

  use Firefly.Changeset
  alias Firefly.Accounts.UserIdentity
  alias Firefly.Discussion.Post
  alias Firefly.Groups.{Role, RoleMembership}

  schema "forums_users" do
    field(:email, :string)
    field(:name, :string)
    field(:username, :string)
    field(:password_hash, :string)
    field(:password, :string, virtual: true)
    field(:confirmed_at, :utc_datetime)
    field(:email_notifications, :boolean, default: true)
    field(:allow_private_messages, :boolean, default: true)
    field(:bio, :string)
    field(:website, :string)
    field(:location, :string)
    field(:theme, :string, default: "system")
    # The interface's language (see FireflyWeb.Locale); nil: their browser's.
    field(:locale, :string)
    # Whether they want the keyboard shortcuts (see the web app's
    # KeyboardShortcuts hook).
    field(:keyboard_shortcuts, :boolean, default: true)
    field(:reply_level, :string, default: "tracking")
    field(:new_thread_level, :string, default: "watching")
    field(:hide_profile_activity, :boolean, default: false)
    field(:hide_from_directory, :boolean, default: false)
    field(:deleted_at, :utc_datetime)
    # When the user last had a page open (see Firefly.Accounts.Visits).
    field(:last_seen_at, :utc_datetime)
    # Uploaded profile images (see Firefly.Uploads.set_profile_image/4).
    field(:avatar_upload_id, :id)
    field(:profile_background_upload_id, :id)
    field(:card_background_upload_id, :id)
    # Hides the profile, user card and last seen from others (see Firefly.Accounts.Profiles).
    field(:hide_profile, :boolean, default: false)
    field(:silenced_until, :utc_datetime)
    field(:silence_reason, :string)
    field(:suspended_until, :utc_datetime)
    field(:suspend_reason, :string)
    # 0 (new user) to 4 (leader), see Firefly.TrustLevels. A locked
    # level is one an admin set, which the periodic review leaves alone.
    field(:trust_level, :integer, default: 0)
    field(:manual_locked_trust_level, :integer)
    field(:trust_level_changed_at, :utc_datetime)
    # How often they get a digest email (nil: the site's default), and when
    # they last got one (see Firefly.Notifications.Digests).
    field(:digest_frequency, :string)
    field(:last_digest_at, :utc_datetime)
    # Browser pushes only while they're away (see Firefly.Notifications.WebPush).
    field(:push_only_when_away, :boolean, default: true)
    # Mailing list mode (see Firefly.Notifications.MailingList), and its
    # count of emails sent on `mailing_list_sent_on`.
    field(:mailing_list_mode, :boolean, default: false)
    field(:mailing_list_no_echo, :boolean, default: true)
    field(:new_device_emails, :boolean, default: true)
    field(:mailing_list_sent_on, :date)
    field(:mailing_list_sent_count, :integer, default: 0)
    # The theme they picked among the selectable ones (see Firefly.Themes).
    field(:theme_id, :id)
    # The badge shown as their title, if it allows that (see Firefly.Badges).
    belongs_to(:title_badge, Firefly.Badges.Badge)
    # The plugin this account acts for (see Firefly.Plugins.Bots), if any.
    field(:plugin_bot, :string)
    # False while the account waits for staff approval (the
    # `must_approve_users` setting, see Firefly.Accounts.UserAdmin).
    field(:approved, :boolean, default: true)
    field(:approved_at, :utc_datetime)
    belongs_to(:approved_by, __MODULE__)

    has_many(:posts, Post)
    has_many(:identities, UserIdentity)
    has_many(:role_memberships, RoleMembership)
    many_to_many(:roles, Role, join_through: RoleMembership, on_replace: :delete)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = user, attrs \\ %{}) do
    user
    |> cast(attrs, [:username, :email, :name])
    |> validate_required([:username, :name])
    |> validate_change(:username, fn :username, username ->
      if reserved_username?(username), do: [username: "is reserved"], else: []
    end)
    |> unique_username()
    |> unique_constraint(:email, name: :forums_users_lower_email_index)
  end

  @doc """
  Usernames are unique in any case ("Alice" and "alice" are the same name;
  each account keeps the case it chose): the unique index on
  `lower(username)` refuses a taken one as "has already been taken".
  """
  def unique_username(changeset),
    do: unique_constraint(changeset, :username, name: :forums_users_lower_username_index)

  @doc """
  Usernames nobody can pick: `deleted-user-<id>` is what account deletion
  renames an account to, so taking it ahead of time would block that
  deletion and let someone pose as a deleted account; and those the
  `reserved_usernames` site setting lists (any case).
  """
  def reserved_username?(username) when is_binary(username) do
    String.match?(username, ~r/^deleted-user-/i) or
      String.downcase(username) in Enum.map(
        Firefly.SiteSettings.get("reserved_usernames"),
        &String.downcase/1
      )
  end

  @doc "The placeholder username of a deleted account."
  def deleted_username(id), do: "deleted-user-#{id}"

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
      :locale,
      :keyboard_shortcuts,
      :reply_level,
      :new_thread_level,
      :hide_profile_activity,
      :hide_from_directory,
      :hide_profile,
      :digest_frequency,
      :push_only_when_away,
      :mailing_list_mode,
      :mailing_list_no_echo,
      :new_device_emails
    ])
    |> validate_required([:theme, :reply_level, :new_thread_level])
    |> validate_inclusion(:theme, themes())
    |> validate_inclusion(:reply_level, reply_levels())
    |> validate_inclusion(:new_thread_level, new_thread_levels())
    |> validate_inclusion(:digest_frequency, Firefly.Notifications.Digests.frequencies())
  end

  @doc "The profile or user card background's URL (`image`: `:profile_background` or `:card_background`), or nil."
  def background_url(%__MODULE__{profile_background_upload_id: id}, :profile_background),
    do: id && "/backgrounds/#{id}"

  def background_url(%__MODULE__{card_background_upload_id: id}, :card_background),
    do: id && "/backgrounds/#{id}"

  @doc "Whether the account was deleted (it remains, anonymized, as its posts' author)."
  def deleted?(%__MODULE__{deleted_at: deleted_at}), do: not is_nil(deleted_at)

  @doc "Whether the user is silenced now: they can read, but not post, message, like or flag."
  def silenced?(%__MODULE__{silenced_until: until}), do: in_force?(until)

  @doc "Whether the user is suspended now: they can't log in."
  def suspended?(%__MODULE__{suspended_until: until}), do: in_force?(until)

  defp in_force?(nil), do: false
  defp in_force?(until), do: DateTime.after?(until, DateTime.utc_now())

  @doc "Whether the account still waits for staff to approve it."
  def pending_approval?(%__MODULE__{approved: approved}), do: approved == false

  @doc "Whether the user has confirmed their email address."
  def confirmed?(%__MODULE__{confirmed_at: confirmed_at}), do: not is_nil(confirmed_at)

  @doc "Sets a new password (password reset)."
  def password_changeset(%__MODULE__{} = user, attrs) do
    {attrs, invalid} = take_invalid_text(attrs)

    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_password_length()
    |> Firefly.Accounts.Passwords.validate_strength([user.username, user.email])
    |> validate_confirmation(:password, message: "does not match password")
    |> put_password_hash()
    |> invalid_text_errors(invalid, [:password, :password_confirmation])
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
    {attrs, invalid} = take_invalid_text(attrs)
    attrs = Map.put_new(attrs, "name", attrs["username"])

    user
    |> changeset(attrs)
    |> cast(attrs, [:password])
    |> validate_required([:email, :password])
    |> validate_format(:username, ~r/^[A-Za-z0-9_-]+$/,
      message: "can only contain letters, numbers, - and _"
    )
    |> validate_length(:username,
      min: Firefly.SiteSettings.get("min_username_length"),
      max: Firefly.SiteSettings.get("max_username_length")
    )
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> validate_password_length()
    |> Firefly.Accounts.Passwords.validate_strength([attrs["username"], attrs["email"]])
    |> validate_username_free()
    |> put_password_hash()
    |> invalid_text_errors(invalid, [:username, :email, :name, :password])
  end

  # Form fields that aren't UTF-8 (a form post can send any bytes): taken
  # out before validation, which can't measure them, and errors after.
  defp take_invalid_text(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    invalid = for {k, v} <- attrs, is_binary(v), not String.valid?(v), do: k
    {Map.drop(attrs, invalid), invalid}
  end

  defp invalid_text_errors(changeset, invalid, fields) do
    for field <- fields, Atom.to_string(field) in invalid, reduce: changeset do
      changeset -> add_error(changeset, field, "isn't valid text")
    end
  end

  # The form says a name is taken before submitting (any case); the unique
  # index has the last word.
  defp validate_username_free(%Ecto.Changeset{valid?: true} = changeset) do
    if Firefly.Accounts.get_user_by_username(get_field(changeset, :username)),
      do: add_error(changeset, :username, "has already been taken"),
      else: changeset
  end

  defp validate_username_free(changeset), do: changeset

  def add_roles(changeset, params) do
    import Ecto.Query

    if Map.get(params, :roles, []) != [] do
      ids = params[:roles]
      # FIXME: I don't love going out to the repo here
      roles = Firefly.Repo.all(from(r in Role, where: r.id in ^ids))
      put_assoc(changeset, :roles, roles)
    else
      changeset
    end
  end

  @doc """
  The user's uploaded avatar, or else their Gravatar, falling back to a
  generated identicon. Users without an email get an identicon derived from
  their username.
  """
  def avatar_url(user, size \\ 256)

  def avatar_url(%__MODULE__{avatar_upload_id: id}, size) when is_integer(id) do
    if size <= Firefly.Uploads.Processor.avatar_thumbnail_size(),
      do: "/avatars/#{id}/small",
      else: "/avatars/#{id}"
  end

  def avatar_url(%__MODULE__{email: email, username: username}, size) do
    (email || "#{username}@users.firestorm.invalid")
    |> Exgravatar.gravatar_url(d: "identicon", s: size)
  end

  # At least `min_password_length` characters, and at most 72 bytes: bcrypt
  # only reads the first 72, so a longer password would also let in any
  # other that starts the same.
  defp validate_password_length(changeset) do
    changeset
    |> validate_length(:password, min: Firefly.SiteSettings.get("min_password_length"))
    |> validate_length(:password,
      max: 72,
      count: :bytes,
      message: "should be at most 72 bytes (fewer characters with accents or emoji)"
    )
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
