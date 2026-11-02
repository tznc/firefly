defmodule Firefly.Auth.DiscourseConnect do
  @moduledoc """
  Logging in through an external DiscourseConnect provider (formerly
  "Discourse SSO"): Firefly is the consumer, the provider (a site that
  owns the accounts) vouches for who the user is.

      config :firefly, Firefly.Auth.DiscourseConnect,
        url: "https://accounts.example.com/discourse/sso",
        secret: "a long shared secret",
        name: "Example Accounts"

  (`FIREFLY_DISCOURSE_CONNECT_*`, see `config/runtime.exs`.)

  The login: we send the browser to the provider with a payload (Base64 of
  `nonce` and `return_sso_url`) and its HMAC-SHA256 signature (`sig`, hex)
  under the shared secret. The provider sends it back to `return_sso_url`
  with a signed payload describing the user. We accept it only if the
  signature matches, and its nonce is one we issued, to this browser
  (it's kept in the session too), under 10 minutes ago, and never used
  before: each nonce is deleted as it's accepted.

  The provider's `external_id` is the account's id (provider
  `"discourse_connect"` in `user_identities`, see `Firefly.Auth`). An
  unknown `external_id` whose email the provider vouches for (no
  `require_activation=true`) is linked to the local account with that
  confirmed email, as Discourse does; otherwise a new account is created
  (if registrations are open), its email confirmed unless
  `require_activation=true`.

  Each login can also bring the account up to date with the provider, each
  part opt-in through a site setting (section "Logins"): email, username,
  name, avatar, the admin and moderator flags (the "admin" and "moderator"
  groups) and group membership (`groups`, `add_groups`, `remove_groups`;
  only groups that exist here). Group changes go to the staff log as the
  system's.
  """

  import Ecto.Query

  alias Firefly.{Auth, Forums, Repo, SiteSettings, StaffLog, Uploads}
  alias Firefly.Forums.{Role, RoleMembership, User, UserIdentity}
  alias Firefly.LinkPreviews.Fetcher

  @nonce_seconds 600
  @image_types ~w(image/png image/jpeg image/gif image/webp)
  @staff_groups ~w(admin moderator)

  defp config, do: Application.get_env(:firefly, __MODULE__, [])

  @doc "Whether a provider URL and secret are configured."
  def enabled?, do: present?(config()[:url]) and present?(config()[:secret])

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc "The provider's name for people (`name`), by default \"DiscourseConnect\"."
  def label, do: if(present?(config()[:name]), do: config()[:name], else: "DiscourseConnect")

  @doc """
  Starts a login: issues a nonce (to keep in the session too) and returns
  `{nonce, url}`, the provider URL to send the browser to, which will come
  back to `return_url`.
  """
  def request(return_url) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    now = DateTime.utc_now(:second)

    Repo.delete_all(from(n in "discourse_connect_nonces", where: n.expires_at < ^now))

    Repo.insert_all("discourse_connect_nonces", [
      %{nonce: nonce, expires_at: DateTime.add(now, @nonce_seconds)}
    ])

    payload = Base.encode64(URI.encode_query(%{"nonce" => nonce, "return_sso_url" => return_url}))
    query = URI.encode_query(%{"sso" => payload, "sig" => sign(payload)})
    url = config()[:url]
    {nonce, url <> if(String.contains?(url, "?"), do: "&", else: "?") <> query}
  end

  @doc "The payload's signature: HMAC-SHA256 under the shared secret, in lowercase hex."
  def sign(payload),
    do: :hmac |> :crypto.mac(:sha256, config()[:secret], payload) |> Base.encode16(case: :lower)

  @doc """
  Checks the provider's answer (`sso` and `sig`) against the nonce this
  browser's login started with, and uses up the nonce. Returns the user's
  fields (`external_id` is required) or `{:error, reason}`: `:bad_signature`,
  `:bad_payload`, `:wrong_nonce` (not this browser's), `:expired_nonce`
  (too old, or used already), `:no_external_id`.
  """
  def verify(sso, sig, session_nonce)
      when is_binary(sso) and is_binary(sig) and is_binary(session_nonce) do
    with :ok <- check_signature(sso, sig),
         {:ok, params} <- decode(sso),
         :ok <- check_nonce(params["nonce"], session_nonce) do
      if present?(params["external_id"]), do: {:ok, params}, else: {:error, :no_external_id}
    end
  end

  def verify(_sso, _sig, _session_nonce), do: {:error, :bad_signature}

  defp check_signature(sso, sig) do
    if Plug.Crypto.secure_compare(sign(sso), String.downcase(sig)),
      do: :ok,
      else: {:error, :bad_signature}
  end

  defp decode(sso) do
    case Base.decode64(sso, ignore: :whitespace) do
      {:ok, query} -> {:ok, URI.decode_query(query)}
      :error -> {:error, :bad_payload}
    end
  end

  defp check_nonce(nonce, session_nonce) when is_binary(nonce) do
    if Plug.Crypto.secure_compare(nonce, session_nonce),
      do: use_nonce(nonce),
      else: {:error, :wrong_nonce}
  end

  defp check_nonce(_nonce, _session_nonce), do: {:error, :wrong_nonce}

  defp use_nonce(nonce) do
    now = DateTime.utc_now(:second)

    case Repo.delete_all(
           from(n in "discourse_connect_nonces",
             where: n.nonce == ^nonce and n.expires_at >= ^now
           )
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :expired_nonce}
    end
  end

  @doc "A message for a `verify/3` error."
  def message(:expired_nonce), do: "That login link expired or was used already. Try again."
  def message(_reason), do: "#{label()} login failed. Try again."

  @doc "What `Firefly.Auth.login/1` and `connect/2` use from the provider's fields."
  def info(params) do
    %{
      provider: :discourse_connect,
      uid: params["external_id"],
      nickname: blank(params["username"]),
      name: blank(params["name"]),
      email: blank(params["email"]),
      avatar_url: blank(params["avatar_url"]),
      email_verified: params["require_activation"] != "true"
    }
  end

  defp blank(value) when is_binary(value), do: if(present?(value), do: value)
  defp blank(_value), do: nil

  @doc "Logs in (or links, or registers) the provider's user, then syncs it (see the moduledoc)."
  def login(params) do
    with {:ok, user} <- Auth.login(info(params)), do: {:ok, sync(user, params)}
  end

  @doc """
  The local account to link an unknown `external_id` to: the one with the
  provider's email, confirmed, when the provider vouches for it, and not
  linked to another provider account already.
  """
  def account_for_email(%{email: email, email_verified: true}) when is_binary(email) do
    Repo.one(
      from(u in User,
        as: :user,
        where: fragment("lower(?)", u.email) == ^String.downcase(email),
        where: not is_nil(u.confirmed_at) and is_nil(u.deleted_at),
        where:
          not exists(
            from(i in UserIdentity,
              where: i.user_id == parent_as(:user).id and i.provider == "discourse_connect"
            )
          ),
        limit: 1
      )
    )
  end

  def account_for_email(_info), do: nil

  @doc "Brings `user` up to date with the provider's fields, as the site settings allow."
  def sync(%User{} = user, params) do
    info = info(params)

    user
    |> sync_fields(info)
    |> sync_avatar(info)
    |> tap(&sync_staff(&1, params))
    |> tap(&sync_groups(&1, params))
    |> tap(&remember(&1, info))
  end

  defp sync_fields(user, info) do
    changes =
      %{}
      |> sync?("discourse_connect_overrides_email", :email, info.email, user.email)
      |> sync?("discourse_connect_overrides_username", :username, info.nickname, user.username)
      |> sync?("discourse_connect_overrides_name", :name, info.name, user.name)

    if changes == %{} do
      user
    else
      changeset =
        user
        |> User.changeset(changes)
        |> Ecto.Changeset.validate_format(:username, ~r/^[A-Za-z0-9_-]+$/)
        |> Ecto.Changeset.validate_length(:username, min: 2, max: 32)
        |> confirmation(changes, info)

      # A username taken here, say, keeps the old one: the login still works.
      case Repo.update(changeset) do
        {:ok, user} -> user
        {:error, _changeset} -> user
      end
    end
  end

  defp sync?(changes, setting, field, new, old) do
    if SiteSettings.get(setting) and is_binary(new) and new != old,
      do: Map.put(changes, field, new),
      else: changes
  end

  defp confirmation(changeset, %{email: _}, info) do
    Ecto.Changeset.put_change(
      changeset,
      :confirmed_at,
      if(info.email_verified, do: DateTime.utc_now(:second))
    )
  end

  defp confirmation(changeset, _changes, _info), do: changeset

  defp sync_avatar(user, %{avatar_url: url}) when is_binary(url) do
    if SiteSettings.get("discourse_connect_overrides_avatar") and
         url != stored(user)["avatar_url"],
       do: fetch_avatar(user, url),
       else: user
  end

  defp sync_avatar(user, _info), do: user

  # Fetched like a link preview's image (public addresses only, size-capped);
  # a failure leaves the avatar as it was.
  defp fetch_avatar(user, url) do
    with {:ok, file} <- Fetcher.get(url, types: @image_types, max_bytes: Uploads.max_size()),
         path = Plug.Upload.random_file!("discourse-connect-avatar"),
         :ok <- File.write(path, file.body),
         {:ok, user} <- Uploads.set_profile_image(user, :avatar, path, "avatar") do
      user
    else
      _failed -> user
    end
  end

  defp sync_staff(user, params) do
    if SiteSettings.get("discourse_connect_sync_staff") do
      for {flag, group} <- [{"admin", "admin"}, {"moderator", "moderator"}],
          params[flag] in ["true", "false"] do
        set_member(user, group, params[flag] == "true")
      end
    end
  end

  # `groups` is the full list of the user's groups (among those that exist
  # here, staff groups aside); `add_groups` and `remove_groups` change it.
  defp sync_groups(user, params) do
    if SiteSettings.get("discourse_connect_overrides_groups") do
      listed = names(params["groups"])

      for name <- unlisted(user, params["groups"], listed), do: set_member(user, name, false)
      for name <- listed ++ names(params["add_groups"]), do: set_member(user, name, true)
      for name <- names(params["remove_groups"]), do: set_member(user, name, false)
    end
  end

  # The user's groups `groups` (when given) leaves out.
  defp unlisted(_user, nil, _listed), do: []

  defp unlisted(user, _groups, listed) do
    Repo.all(
      from(r in Role,
        join: m in RoleMembership,
        on: m.role_id == r.id and m.user_id == ^user.id,
        where: r.name not in ^(@staff_groups ++ listed),
        select: r.name
      )
    )
  end

  defp names(list) when is_binary(list) do
    list
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or &1 in @staff_groups))
  end

  defp names(_list), do: []

  # Staff groups are created when first granted; others must exist.
  defp set_member(user, name, member?) do
    role =
      Repo.get_by(Role, name: name) ||
        if(member? and name in @staff_groups, do: elem(Forums.create_role(name), 1))

    if role, do: set_membership(user, role, member?)
  end

  defp set_membership(user, role, member?) do
    membership =
      Repo.one(from(m in RoleMembership, where: m.role_id == ^role.id and m.user_id == ^user.id))

    details = %{role: role.name, username: user.username}

    cond do
      member? and is_nil(membership) ->
        {:ok, _} = Forums.add_role(user, role)
        StaffLog.record_system("role.grant", user, details)

      not member? and membership != nil ->
        Repo.delete!(membership)
        StaffLog.record_system("role.revoke", user, details)

      true ->
        :ok
    end
  end

  defp stored(user) do
    case Repo.get_by(UserIdentity, user_id: user.id, provider: "discourse_connect") do
      %UserIdentity{info: info} -> info
      nil -> %{}
    end
  end

  # What the provider last said, shown in the user's settings (and the
  # avatar URL, so an unchanged avatar isn't fetched again).
  defp remember(user, info) do
    case Repo.get_by(UserIdentity, user_id: user.id, provider: "discourse_connect") do
      nil ->
        :ok

      identity ->
        fields =
          info
          |> Map.take([:nickname, :name, :email, :avatar_url])
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        identity |> Ecto.Changeset.change(info: fields) |> Repo.update!()
    end
  end
end
