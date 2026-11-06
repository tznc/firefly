defmodule Firefly.Accounts.ApiKeys do
  @moduledoc """
  API keys for the JSON API (`/api/v1`) and the MCP server.

  A member creates keys for themselves (Settings > API keys); admins also
  create global keys (`/staff/api-keys`), which act as the user a request
  names (the `Api-Username` header; else the admin who made the key) and
  only while that admin is still an admin.

  A key is a random token shown once, when it's made: only its SHA-256 is
  stored. Each key has:

    * scopes, what it may do (see `scopes/0`); a request also needs the
      user's own permissions, as in the web interface
    * an optional expiry, and allowed client addresses or CIDR ranges
    * a rate limit in requests per minute (default: the `api_rate_limit`
      site setting)
    * when and from where it was last used

  Revoked and expired keys stop working at once.
  """

  import Ecto.Query

  alias Firefly.{Accounts, RateLimit, Repo, Security, SiteSettings}
  alias Firefly.Accounts.{ApiKey, User}
  alias Firefly.Moderation.StaffLog

  @scopes [
    {"read", "Read everything the user may read"},
    {"write", "Every write below (not admin)"},
    {"topics:write",
     "Threads and posts: create, edit, delete, like, bookmark, vote, accept answers, flag"},
    {"messages:write", "Private messages"},
    {"chat:write", "Chat channels and messages"},
    {"uploads:write", "Upload files"},
    {"users:write", "Profile, preferences, notification levels and groups"},
    {"notifications:write", "Mark notifications read"},
    {"admin", "Staff actions, for an admin: review queue, users, site settings, webhooks, badges"}
  ]

  @scope_names Enum.map(@scopes, &elem(&1, 0))

  # The token's recognizable start (as secret scanners like).
  @token_prefix "ffk_"

  # last_used_at is written at most this often per key.
  @touch_every 60

  @doc "Every scope a key can have, as `{scope, description}`."
  def scopes, do: @scopes

  @doc "The scope names."
  def scope_names, do: @scope_names

  @doc "The scopes that allow everything: what login tokens and migrated tokens get."
  def full_scopes, do: ~w(read write admin)

  @doc """
  Whether `key` has `scope`: `read` and `admin` must be listed; `write`
  covers every `*:write` scope.
  """
  def allows?(%ApiKey{scopes: scopes}, scope) do
    scope in scopes or (String.ends_with?(scope, ":write") and "write" in scopes)
  end

  @doc "A changeset for the key form."
  def change(attrs \\ %{}), do: ApiKey.changeset(%ApiKey{}, attrs, @scope_names)

  @doc """
  Creates a key for `user`: `{:ok, key, token}`, the token being the only
  time the key is ever seen in full.
  """
  def create(%User{} = user, attrs),
    do: insert(%ApiKey{user_id: user.id, created_by_id: user.id}, attrs)

  @doc "Creates a global key (admins only), logged in the staff log."
  def create_global(%User{} = admin, attrs) do
    if Accounts.admin?(admin),
      do: insert_global(admin, attrs),
      else: {:error, :unauthorized}
  end

  defp insert_global(admin, attrs) do
    result =
      Repo.transact(fn ->
        with {:ok, key, token} <- insert(%ApiKey{created_by_id: admin.id}, attrs) do
          StaffLog.record(admin, "api_key.create", {"api_key", key.id}, %{"name" => key.name})
          {:ok, {key, token}}
        end
      end)

    with {:ok, {key, token}} <- result, do: {:ok, key, token}
  end

  defp insert(key, attrs) do
    token = @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    key
    |> ApiKey.changeset(attrs, @scope_names)
    |> Ecto.Changeset.change(token_hash: hash(token), prefix: String.slice(token, 0, 8))
    |> Repo.insert()
    |> case do
      {:ok, key} ->
        Security.record("api_key.create", key.user_id, %{name: key.name, prefix: key.prefix})
        {:ok, key, token}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "A full-scope key for `user` (`{:ok, key, token}`), as an API password login hands out."
  def create_login_key(%User{} = user, name \\ "API login"),
    do: create(user, %{name: name, scopes: full_scopes()})

  defp hash(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)

  @doc "`user`'s own keys, newest first (revoked ones too)."
  def list(%User{id: user_id}) do
    Repo.all(from(k in ApiKey, where: k.user_id == ^user_id, order_by: [desc: k.id]))
  end

  @doc "Every key, newest first, with their user and creator (for admins)."
  def list_all do
    Repo.all(from(k in ApiKey, order_by: [desc: k.id], preload: [:user, :created_by]))
  end

  @doc "A key by id, or nil."
  def get(id), do: Repo.get(ApiKey, id)

  @doc """
  Revokes `key`: its own user may, and admins may revoke any (logged when
  it isn't their own).
  """
  def revoke(%ApiKey{} = key, %User{} = actor) do
    cond do
      key.user_id == actor.id ->
        do_revoke(key)

      Accounts.admin?(actor) ->
        Repo.transact(fn ->
          StaffLog.record(actor, "api_key.revoke", {"api_key", key.id}, %{"name" => key.name})
          do_revoke(key)
        end)

      true ->
        {:error, :unauthorized}
    end
  end

  defp do_revoke(%ApiKey{revoked_at: nil} = key) do
    Security.record("api_key.revoke", key.user_id, %{name: key.name, prefix: key.prefix})
    key |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second)) |> Repo.update()
  end

  defp do_revoke(key), do: {:ok, key}

  @doc "Revokes all of `user`'s keys (account deletion)."
  def revoke_all(%User{id: user_id}) do
    query = from(k in ApiKey, where: k.user_id == ^user_id and is_nil(k.revoked_at))
    Repo.update_all(query, set: [revoked_at: DateTime.utc_now(:second)])
    :ok
  end

  @doc """
  The key `token` is and the user a request with it acts as, when used
  from `ip`: `{:ok, key, user}`, or `{:error, reason}` with reason
  `:invalid` (unknown, revoked or expired), `:ip_not_allowed`, `:no_user`
  (a global key naming nobody usable) or `:rate_limited`.

  `username` is the `Api-Username` a global key acts as (ignored for
  members' keys). Deleted and suspended users' keys don't work.
  """
  def authenticate(token, ip, username \\ nil)

  def authenticate(token, ip, username) when is_binary(token) and token != "" do
    with %ApiKey{} = key <- Repo.get_by(ApiKey, token_hash: hash(token)),
         false <- ApiKey.inactive?(key),
         {:ip, true} <- {:ip, ApiKey.ip_allowed?(key, ip)},
         %User{} = user <- acting_user(key, username),
         :ok <- RateLimit.check_api(key.id, rate_limit(key)) do
      {:ok, touch(key, ip), user}
    else
      {:ip, false} -> {:error, :ip_not_allowed}
      {:error, :rate_limited} -> {:error, :rate_limited}
      :no_user -> {:error, :no_user}
      _invalid -> {:error, :invalid}
    end
  end

  def authenticate(_token, _ip, _username), do: {:error, :invalid}

  @doc "The requests per minute `key` may make."
  def rate_limit(%ApiKey{rate_limit: nil}), do: SiteSettings.get("api_rate_limit")
  def rate_limit(%ApiKey{rate_limit: limit}), do: limit

  defp acting_user(%ApiKey{user_id: nil, created_by_id: creator_id}, username) do
    creator = creator_id && Accounts.get_user(creator_id)

    user =
      cond do
        creator == nil or not Accounts.admin?(creator) -> nil
        username in [nil, ""] -> creator
        true -> Accounts.get_user_by_username(username)
      end

    usable(user) || :no_user
  end

  defp acting_user(%ApiKey{user_id: user_id}, _username), do: usable(Accounts.get_user(user_id))

  defp usable(%User{deleted_at: nil} = user), do: if(User.suspended?(user), do: nil, else: user)
  defp usable(_user), do: nil

  defp touch(key, ip) do
    now = DateTime.utc_now(:second)
    ip = format_ip(ip)

    # The first use from each address goes in the security log.
    if key.last_used_ip != ip,
      do:
        Security.record("api_key.use", key.user_id, %{name: key.name, prefix: key.prefix}, ip: ip)

    if key.last_used_at == nil or key.last_used_ip != ip or
         DateTime.diff(now, key.last_used_at) >= @touch_every do
      key |> Ecto.Changeset.change(last_used_at: now, last_used_ip: ip) |> Repo.update!()
    else
      key
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: to_string(ip)
end
