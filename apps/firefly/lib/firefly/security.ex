defmodule Firefly.Security do
  @moduledoc """
  The Security context: the security log, and how long IP addresses are kept.

  ## The security log

  `record/3` adds an event (`Firefly.Security.Event`) for what matters to an
  account's safety: logins and failed attempts, two-factor and passkey
  changes, password resets, API keys (created, first used from an address,
  revoked), signed-out sessions, penalties and IP bans, quarantined uploads.
  Members see their own events in their security settings
  (`for_user/2`); admins see everything at `/staff/security` (`list/2`).

  The client (IP address and user agent) comes from the request being
  served: the web app remembers it for each request and LiveView (see
  `Firefly.Moderation.Akismet.client/0`), and `:ip`/`:user_agent` options
  override it.

  ## IP retention

  The `ip_retention_days` setting (default 90) is how long full IP
  addresses are kept. `run_retention/1` (hourly, `Firefly.Jobs.Periodic`)
  truncates older ones to their /24 (IPv4) or /48 (IPv6) network wherever
  Firefly stores them, or deletes the row where a truncated address is
  useless (see `ip_tables/0`).
  """

  use Boundary, top_level?: true, check: [out: false], exports: [Event, Ban, Jail, Challenge]

  import Ecto.Query

  alias Firefly.{Accounts, Backups, Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Security.{Event, Jail}

  @kinds ~w(
    login.success login.failure two_factor.failure passkey.failure
    two_factor.enable two_factor.disable two_factor.backup_codes two_factor.key_add
    two_factor.key_remove two_factor.reset passkey.add passkey.remove password.reset
    api_key.create api_key.use api_key.revoke session.revoke
    account.suspend account.unsuspend account.silence account.unsilence
    ip.ban ip.unban upload.quarantine
  )

  @doc "Every kind of event."
  def kinds, do: @kinds

  @doc """
  Records the event `kind` about `user` (a `User`, an id or nil) with
  `details` (string-keyed once stored). Options: `:ip` and `:user_agent`,
  else the current request's (see the module doc). Nothing is recorded while
  the site is read-only. Returns `:ok`.
  """
  def record(kind, user, details \\ %{}, opts \\ []) when kind in @kinds do
    if not Backups.read_only?() do
      client = Firefly.Moderation.Akismet.client()

      Repo.insert!(%Event{
        kind: kind,
        user_id: user_id(user),
        ip: format_ip(Keyword.get(opts, :ip, client[:ip])),
        user_agent: user_agent(Keyword.get(opts, :user_agent, client[:user_agent])),
        details: details
      })
    end

    :ok
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_integer(id) or is_nil(id), do: id

  defp format_ip(nil), do: nil
  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: ip |> to_string() |> String.slice(0, 45)

  defp user_agent(nil), do: nil
  defp user_agent(agent), do: String.slice(agent, 0, 512)

  @doc """
  A failed login attempt (`kind`: `"login.failure"`, `"two_factor.failure"`,
  `"passkey.failure"`) for the account named `username` (or `user`), if
  there's one: recorded against it, so its member sees it, and a signal
  for the jail (see `Firefly.Security.Jail`).
  """
  def login_failed(kind, user_or_username, details \\ %{})

  def login_failed(kind, %User{} = user, details) do
    Jail.signal_client(String.replace(kind, ".", "_"), %{user: user.username})
    record(kind, user, details)
  end

  def login_failed(kind, username, details) do
    Jail.signal_client(String.replace(kind, ".", "_"))
    user = if is_binary(username) and username != "", do: Accounts.get_user_by_username(username)
    record(kind, user, Map.put(details, :username, username))
  end

  @doc "`user`'s latest events, newest first."
  def for_user(%User{id: user_id}, limit \\ 50) do
    Event
    |> where([e], e.user_id == ^user_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  A page of every event, newest first, with their users: `filters` (string
  keys) narrow it by `"kind"` and `"q"` (a username, or an address or its
  start).
  """
  def list(filters \\ %{}, page \\ 1) do
    Event
    |> filter_kind(filters["kind"])
    |> filter_query(String.trim(filters["q"] || ""))
    |> order_by(desc: :inserted_at, desc: :id)
    |> preload(:user)
    |> Repo.paginate(page: page, page_size: 50)
  end

  defp filter_kind(query, kind) when kind in @kinds, do: where(query, [e], e.kind == ^kind)
  defp filter_kind(query, _kind), do: query

  defp filter_query(query, ""), do: query

  defp filter_query(query, q) do
    prefix = String.replace(q, ~r/[\\%_]/, "\\\\\\0") <> "%"

    from(e in query,
      left_join: u in assoc(e, :user),
      where: like(e.ip, ^prefix) or fragment("lower(?)", u.username) == ^String.downcase(q)
    )
  end

  ## Login delays

  @delay_window_minutes 15

  @doc """
  How long (milliseconds) to hold a password login for `username` from
  `ip` before checking it: nothing for the first 3 recent failures, then
  250 ms doubling with each further one, up to
  `config :firefly, Firefly.Security, max_login_delay_ms:` (5 seconds).
  Counted per account (its failed logins in the security log in the last
  15 minutes) and per address (its points in the jail's `auth` group), the
  longer winning, so neither guessing one account from many addresses nor
  many accounts from one address goes at full speed.
  """
  def login_delay(username, ip) do
    account =
      case is_binary(username) and username != "" and Accounts.get_user_by_username(username) do
        %User{} = user -> recent_login_failures(user)
        _nobody -> 0
      end

    max(delay(account), delay(Jail.points(ip, "auth")))
  end

  @doc "How many failed logins `user` had in the last 15 minutes."
  def recent_login_failures(%User{id: user_id}) do
    since = DateTime.add(DateTime.utc_now(), -@delay_window_minutes, :minute)

    Repo.aggregate(
      from(e in Event,
        where: e.user_id == ^user_id and e.kind == "login.failure" and e.inserted_at > ^since
      ),
      :count
    )
  end

  defp delay(failures) when failures < 3, do: 0

  defp delay(failures) do
    max_ms = Application.get_env(:firefly, __MODULE__, [])[:max_login_delay_ms] || 5_000
    min(max_ms, 250 * Integer.pow(2, min(failures - 3, 10)))
  end

  ## IP retention

  @doc """
  An address with its host part zeroed: its /24 for IPv4, /48 for IPv6
  (text in, text out; anything else is returned as it is).
  """
  def anonymize_ip(ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(ip)) do
      {:ok, {a, b, c, _d}} -> to_string(:inet.ntoa({a, b, c, 0}))
      {:ok, {a, b, c, _, _, _, _, _}} -> to_string(:inet.ntoa({a, b, c, 0, 0, 0, 0, 0}))
      {:error, _} -> ip
    end
  end

  @doc """
  Where Firefly stores IP addresses and what retention does to each:
  `{table, column, timestamp column, :truncate | :delete}`.
  """
  def ip_tables do
    [
      {"security_events", "ip", "inserted_at", :truncate},
      {"api_keys", "last_used_ip", "last_used_at", :truncate},
      {"user_sessions", "ip", "last_seen_at", :truncate},
      # The addresses staff look members up by: a truncated one would match
      # strangers (and collide with the per-member unique index).
      {"user_ips", "ip", "last_seen_at", :delete},
      # Bans are deleted by Jail.run_cleanup/1 once ended this long ago.
      # The client sent with each Akismet check, in its params.
      {"akismet_checks", "params->>'user_ip'", "inserted_at", :truncate}
    ]
  end

  @doc """
  Truncates or deletes the IP addresses older than `ip_retention_days` (as
  of `now`). Returns how many rows changed, by table.
  """
  # Sobelow: the SQL is built from ip_tables/0's fixed names; the cutoff is
  # a parameter.
  # sobelow_skip ["SQL.Query"]
  def run_retention(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -SiteSettings.get("ip_retention_days"), :day)

    Map.new(ip_tables(), fn {table, column, at, action} ->
      %{num_rows: count} = Repo.query!(retention_sql(table, column, at, action), [cutoff])
      {table, count}
    end)
  end

  # Postgres does the truncating: `cidr/1` zeroes the bits past the mask.
  # Addresses that don't parse ("unknown") are left alone. Table and column
  # names come from ip_tables/0, never from input.
  defp retention_sql(table, column, at, :delete),
    do: "DELETE FROM #{table} WHERE #{at} < $1 AND #{column} IS NOT NULL"

  defp retention_sql("akismet_checks" = table, column, at, :truncate) do
    """
    UPDATE #{table} SET params = jsonb_set(params, '{user_ip}', to_jsonb(#{truncated(column)}))
    WHERE #{at} < $1 AND pg_input_is_valid(#{column}, 'inet') AND #{column} <> #{truncated(column)}
    """
  end

  defp retention_sql(table, column, at, :truncate) do
    """
    UPDATE #{table} SET #{column} = #{truncated(column)}
    WHERE #{at} < $1 AND pg_input_is_valid(#{column}, 'inet') AND #{column} <> #{truncated(column)}
    """
  end

  defp truncated(column) do
    "CASE family((#{column})::inet) " <>
      "WHEN 4 THEN host(cidr(set_masklen((#{column})::inet, 24))) " <>
      "ELSE host(cidr(set_masklen((#{column})::inet, 48))) END"
  end
end
