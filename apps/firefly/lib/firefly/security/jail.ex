defmodule Firefly.Security.Jail do
  @moduledoc """
  Fail2ban for Firefly: addresses that keep failing get banned.

  ## Signals

  Whatever notices abuse reports it with `signal/3` (or `signal_client/2`,
  for the current request's address): the kind names the signal group it
  counts in, its *jail*, and how many points it's worth (`kinds/0`):

  | Jail | Signals |
  | --- | --- |
  | `auth` | failed logins, two-factor and passkey failures, magic-link abuse, API key failures |
  | `rate_limit` | rate limits hit (see `Firefly.RateLimit`) |
  | `probe` | 404s (1 point), requests for exploit paths such as `/wp-login.php` or `/.env` (10) |
  | `csrf` | CSRF failures and invalid or expired signed tokens |
  | `spam` | Akismet spam verdicts, watched-word blocks, screening hits |
  | `signature` | webhook and inbound-email signature failures |
  | `bot` | failed bot challenges |
  | `plugin` | what plugins report (`jail.signal`, see PLUGINS.md) |

  A jail bans an address once its points within the jail's find time reach
  its threshold (`jail_<name>_threshold`, `jail_<name>_findtime` minutes).
  The ban lasts `jail_<name>_bantime` minutes, multiplied by
  `jail_bantime_factor` for each earlier ban of the address (fail2ban's
  `bantime.increment`), up to `jail_max_ban_hours`. IPv4 addresses are
  banned one by one; IPv6 ones by their /64 (`jail_ipv6_prefix`: 64, or 128
  for single addresses), since one host usually holds a whole /64.

  Never banned: the `jail_allowlist` setting's addresses and ranges, and
  the trusted proxies (`FIREFLY_TRUSTED_PROXIES`, which every request would
  otherwise come from). Staff ban and unban addresses and ranges by hand
  (`ban/2`, `unban/2`), staff-logged. Every ban is also in the security log
  (`Firefly.Security`), and plugins that asked to hear of them get the
  `ip_banned` and `ip_unbanned` events.

  ## State

  Signal points are counted per node in ETS, in time buckets (a tenth of the
  find time) summed over the window (see `Firefly.Security.Jail.Tables`).
  Bans are rows in `bans` (`Firefly.Security.Ban`), so they survive
  restarts, and each node caches the ones in force in ETS, kept in step over
  `Firefly.PubSub` (cluster-wide when clustering is on). The web app checks
  every request against that cache (`banned/1`, `FireflyWeb.Plugs.Jail`).
  `run_cleanup/0` (an Oban cron task) deletes ban rows once they ended
  longer ago than `ip_retention_days`.

  The jail is off when the `jail_enabled` setting is, and in tests unless a
  test turns it on (`config :firefly, Firefly.Security.Jail, enabled: false`).

  Metrics: `[:firefly, :security, :signal]` (`jail`, `kind`) and
  `[:firefly, :security, :ban]` (`jail`, `source`) telemetry events, never
  with the address.
  """

  import Bitwise
  import Ecto.Query
  require Logger

  alias Firefly.{IPRange, Repo, Security, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Moderation.StaffLog
  alias Firefly.Security.Ban
  alias Firefly.Security.Jail.Tables

  # name => {default threshold (points), find time (minutes), ban time (minutes)}
  @jails [
    {"auth", "logins", {10, 10, 30}},
    {"rate_limit", "rate limits", {30, 10, 30}},
    {"probe", "scanning", {30, 10, 60}},
    {"csrf", "forged requests and invalid tokens", {10, 10, 30}},
    {"spam", "spam", {5, 60, 120}},
    {"signature", "signature failures", {10, 10, 60}},
    {"bot", "bot challenges", {10, 10, 30}},
    {"plugin", "plugin reports", {20, 10, 30}}
  ]

  # kind => {jail, points}
  @kinds %{
    "login_failure" => {"auth", 1},
    "two_factor_failure" => {"auth", 1},
    "passkey_failure" => {"auth", 1},
    "magic_link_abuse" => {"auth", 1},
    "api_key_failure" => {"auth", 1},
    "rate_limited" => {"rate_limit", 1},
    "not_found" => {"probe", 1},
    "exploit_probe" => {"probe", 10},
    "csrf" => {"csrf", 1},
    "invalid_token" => {"csrf", 1},
    "akismet_spam" => {"spam", 1},
    "watched_word" => {"spam", 1},
    "screening" => {"spam", 1},
    "signature" => {"signature", 1},
    "bot_challenge" => {"bot", 1},
    "plugin" => {"plugin", 1}
  }

  @doc "The jails' names."
  def jails, do: Enum.map(@jails, &elem(&1, 0))

  @doc "Every signal kind: `%{kind => {jail, points}}`."
  def kinds, do: @kinds

  @doc "The jail settings (see `Firefly.SiteSettings`), in the Security > Banning section."
  def setting_definitions do
    [
      %{
        key: "jail_enabled",
        section: "Banning",
        type: :boolean,
        label: "Ban abusive addresses",
        default: true,
        help:
          "Addresses that keep failing logins, hitting rate limits, probing for exploits, failing CSRF or bot checks, or posting spam are banned for a while (403 on every page)."
      },
      %{
        key: "jail_allowlist",
        section: "Banning",
        type: :list,
        label: "Never ban",
        default: [],
        help:
          "Addresses or ranges (CIDR, like 10.0.0.0/8), separated by commas. The trusted proxies (FIREFLY_TRUSTED_PROXIES) are never banned either."
      },
      %{
        key: "jail_ipv6_prefix",
        section: "Banning",
        type: :select,
        label: "IPv6 bans cover",
        default: "64",
        options: [{"The address's /64 network", "64"}, {"The single address", "128"}],
        help: "One IPv6 host usually has a whole /64 to pick addresses from."
      },
      %{
        key: "jail_bantime_factor",
        section: "Banning",
        type: :integer,
        label: "Repeat ban multiplier",
        default: 2,
        min: 1,
        max: 10,
        help: "Each further ban of the same address lasts this many times longer."
      },
      %{
        key: "jail_max_ban_hours",
        section: "Banning",
        type: :integer,
        label: "Longest automatic ban (hours)",
        default: 168,
        min: 1,
        max: 8760,
        help: "However often an address is banned, a ban lasts no longer than this."
      }
    ] ++
      Enum.flat_map(@jails, fn {name, label, {threshold, findtime, bantime}} ->
        [
          %{
            key: "jail_#{name}_threshold",
            section: "Banning",
            type: :integer,
            label: "Ban for #{label} after (points)",
            default: threshold,
            min: 1,
            max: 10_000,
            help:
              "Points within the find time below that ban an address (see Banning in docs/security.md)."
          },
          %{
            key: "jail_#{name}_findtime",
            section: "Banning",
            type: :integer,
            label: "Find time for #{label} (minutes)",
            default: findtime,
            min: 1,
            max: 1440,
            help: "The window the points are counted in."
          },
          %{
            key: "jail_#{name}_bantime",
            section: "Banning",
            type: :integer,
            label: "First ban for #{label} (minutes)",
            default: bantime,
            min: 1,
            max: 525_600,
            help: "How long a first ban lasts."
          }
        ]
      end)
  end

  ## Whether it's on

  @doc "Whether the deployment allows the jail (off in tests unless turned on)."
  def configured?, do: Keyword.get(config(), :enabled, true)

  @doc "Whether the jail is on: configured and the `jail_enabled` setting."
  def enabled?, do: configured?() and SiteSettings.get("jail_enabled")

  defp config, do: Application.get_env(:firefly, __MODULE__, [])

  @doc """
  Whether `address` (a tuple or text) is never banned: the `jail_allowlist`
  setting and the trusted proxies.
  """
  def exempt?(address) do
    address = IPRange.address(address)

    ranges =
      (Keyword.get(config(), :trusted_proxies, []) ++ SiteSettings.get("jail_allowlist"))
      |> Enum.flat_map(fn range ->
        case IPRange.parse(range) do
          {:ok, parsed} -> [parsed]
          :error -> []
        end
      end)

    is_nil(address) or IPRange.member?(address, ranges)
  end

  ## Signals

  @doc """
  Reports `kind` (see `kinds/0`) from `address` (a tuple or text; nil is
  ignored), with `meta` (only for the log line when it bans). Returns `:ok`,
  or `{:banned, ban}` when this signal banned the address.
  """
  def signal(address, kind, meta \\ %{}, now \\ DateTime.utc_now())

  def signal(nil, _kind, _meta, _now), do: :ok

  def signal(address, kind, meta, now) when is_map_key(@kinds, kind) do
    {jail, points} = @kinds[kind]

    :telemetry.execute([:firefly, :security, :signal], %{count: 1, points: points}, %{
      jail: jail,
      kind: kind
    })

    with true <- enabled?(),
         %{} = parsed <- parse(address),
         false <- exempt?(parsed.address),
         nil <- cached_ban(parsed, now) do
      count(jail, parsed, points, now, meta)
    else
      _ -> :ok
    end
  end

  @doc "`signal/3` for the address of the request being served (see `Firefly.Security.record/4`)."
  def signal_client(kind, meta \\ %{}),
    do: signal(Firefly.Moderation.Akismet.client()[:ip], kind, meta)

  defp count(jail, parsed, points, now, meta) do
    findtime_ms = SiteSettings.get("jail_#{jail}_findtime") * 60_000
    bucket_ms = max(div(findtime_ms, 10), 1000)
    now_ms = DateTime.to_unix(now, :millisecond)
    bucket = div(now_ms, bucket_ms)
    key = {jail, parsed.key, bucket, bucket_ms}
    :ets.update_counter(Tables.counters(), key, points, {key, 0})

    if points(jail, parsed.key, bucket_ms, bucket - 9) >=
         SiteSettings.get("jail_#{jail}_threshold") do
      clear(jail, parsed.key)
      {:ok, ban} = put_ban(parsed.key, jail, "#{jail}: #{reason(meta)}", nil, now)
      {:banned, ban}
    else
      :ok
    end
  end

  @doc """
  The points `address` has in `jail` within its find time on this node (0
  while the jail is off: nothing is counted then).
  """
  def points(address, jail, now \\ DateTime.utc_now()) do
    with true <- configured?(),
         %{} = parsed <- parse(address) do
      findtime_ms = SiteSettings.get("jail_#{jail}_findtime") * 60_000
      bucket_ms = max(div(findtime_ms, 10), 1000)
      points(jail, parsed.key, bucket_ms, div(DateTime.to_unix(now, :millisecond), bucket_ms) - 9)
    else
      _ -> 0
    end
  end

  # The points in the window: the last ten buckets.
  defp points(jail, key, bucket_ms, from) do
    counts =
      :ets.select(Tables.counters(), [
        {{{jail, key, :"$1", bucket_ms}, :"$2"}, [{:>=, :"$1", from}], [:"$2"]}
      ])

    Enum.sum(counts)
  end

  defp clear(jail, key), do: :ets.match_delete(Tables.counters(), {{jail, key, :_, :_}, :_})

  defp reason(meta) when meta == %{}, do: "threshold reached"
  defp reason(meta), do: Enum.map_join(meta, ", ", fn {k, v} -> "#{k}=#{v}" end)

  @doc """
  The addresses with points on this node now, most first: `[%{key, jail,
  points, threshold}]` (for staff; counters are per node).
  """
  def offenders(limit \\ 20, now \\ DateTime.utc_now()) do
    now_ms = DateTime.to_unix(now, :millisecond)
    counters = :ets.tab2list(Tables.counters())

    counters
    |> Enum.filter(fn {{jail, _key, bucket, bucket_ms}, _n} ->
      bucket * bucket_ms > now_ms - SiteSettings.get("jail_#{jail}_findtime") * 60_000
    end)
    |> Enum.group_by(fn {{jail, key, _, _}, _} -> {jail, key} end, fn {_, n} -> n end)
    |> Enum.map(fn {{jail, key}, ns} ->
      %{
        key: key,
        jail: jail,
        points: Enum.sum(ns),
        threshold: SiteSettings.get("jail_#{jail}_threshold")
      }
    end)
    |> Enum.sort_by(&(&1.points / &1.threshold), :desc)
    |> Enum.take(limit)
  end

  ## Addresses and keys

  # An address and the key it's counted and banned under: itself, or for
  # IPv6 its /64 (jail_ipv6_prefix).
  defp parse(address) do
    case IPRange.address(address) do
      nil -> nil
      tuple -> %{address: tuple, key: key(tuple)}
    end
  end

  defp key({_, _, _, _} = address), do: address |> :inet.ntoa() |> to_string()

  defp key(address) do
    case SiteSettings.get("jail_ipv6_prefix") do
      "128" -> address |> :inet.ntoa() |> to_string()
      _ -> network64(address)
    end
  end

  defp network64({a, b, c, d, _, _, _, _}),
    do: "#{{a, b, c, d, 0, 0, 0, 0} |> :inet.ntoa() |> to_string()}/64"

  ## Bans

  @doc """
  The ban in force on `address` (a tuple or text), from this node's cache,
  or nil: `%{key, until, jail}` (`until` a `DateTime`, or nil for never).
  """
  def banned(address, now \\ DateTime.utc_now()) do
    with true <- enabled?(),
         %{} = parsed <- parse(address),
         %{} = ban <- cached_ban(parsed, now),
         false <- exempt?(parsed.address) do
      ban
    else
      _ -> nil
    end
  end

  defp cached_ban(parsed, now) do
    now_ms = DateTime.to_unix(now, :millisecond)
    address_key = parsed.address |> :inet.ntoa() |> to_string()

    keys =
      if tuple_size(parsed.address) == 8,
        do: Enum.uniq([address_key, network64(parsed.address)]),
        else: [address_key]

    exact = Enum.flat_map(keys, &:ets.lookup(Tables.bans(), &1))

    range_bans =
      :ets.select(Tables.bans(), [{{:_, :_, :_, :"$1"}, [{:"/=", :"$1", nil}], [:"$_"]}])

    ranges =
      Enum.filter(range_bans, fn {_key, _until, _jail, range} ->
        IPRange.contains?(range, parsed.address)
      end)

    Enum.find_value(exact ++ ranges, fn {key, until, jail, _range} ->
      if until == :infinity or until > now_ms,
        do: %{
          key: key,
          jail: jail,
          until: if(until == :infinity, do: nil, else: DateTime.from_unix!(until, :millisecond))
        }
    end)
  end

  @doc "The bans in force, newest first, with who made them."
  def active_bans(now \\ DateTime.utc_now()) do
    Ban
    |> where([b], is_nil(b.banned_until) or b.banned_until > ^now)
    |> order_by(desc: :updated_at, desc: :id)
    |> preload(:created_by)
    |> Repo.all()
  end

  @doc """
  Bans `target` (an address or a CIDR range) as `admin`: `opts` `:minutes`
  (nil: forever) and `:reason`. Staff-logged. `{:ok, ban}` or
  `{:error, message}`.
  """
  def ban(target, %User{} = admin, opts \\ []) do
    now = DateTime.utc_now()

    with {:ok, key} <- manual_key(target),
         :ok <- bannable(key) do
      until = if opts[:minutes], do: DateTime.add(now, opts[:minutes], :minute)
      reason = String.slice(opts[:reason] || "", 0, 250)

      Repo.transact(fn ->
        {:ok, ban} = put_ban(key, "manual", reason, admin, now, until)

        StaffLog.record(admin, "ip.ban", {"ban", ban.id}, %{
          ip: key,
          until: until && DateTime.to_iso8601(until),
          reason: reason
        })

        {:ok, ban}
      end)
    end
  end

  defp manual_key(target) do
    target = String.trim(to_string(target))

    case IPRange.parse(target) do
      {:ok, {address, bits}} when bits in [32, 128] ->
        {:ok, address |> :inet.ntoa() |> to_string()}

      {:ok, {address, bits}} ->
        {:ok, "#{address |> masked(bits) |> :inet.ntoa()}/#{bits}"}

      :error ->
        {:error, "That isn't an IP address or range."}
    end
  end

  # A range's network address, host bits zeroed.
  defp masked(address, bits) do
    size = if tuple_size(address) == 4, do: 8, else: 16
    total = tuple_size(address) * size

    integer = address |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< size ||| &1))
    integer = (integer >>> (total - bits)) <<< (total - bits)

    for(i <- (tuple_size(address) - 1)..0//-1, do: integer >>> (i * size) &&& (1 <<< size) - 1)
    |> List.to_tuple()
  end

  defp bannable(key) do
    [address | _bits] = String.split(key, "/")

    if exempt?(address),
      do: {:error, "That address is on the never-ban list or a trusted proxy."},
      else: :ok
  end

  # Inserts or extends the ban on `key`. An automatic one (`until` not
  # given) lasts the jail's ban time times the factor per earlier offence.
  defp put_ban(key, jail, reason, admin, now, until \\ :auto) do
    previous = Repo.get_by(Ban, ip: key)
    offences = if previous, do: previous.offences + 1, else: 1
    until = if until == :auto, do: ban_until(jail, offences, now), else: until

    {:ok, ban} =
      (previous || %Ban{ip: key})
      |> Ecto.Changeset.change(
        jail: jail,
        reason: reason,
        offences: offences,
        banned_until: until && DateTime.truncate(until, :second),
        created_by_id: admin && admin.id
      )
      |> Repo.insert_or_update()

    announce_ban(ban, if(admin, do: :manual, else: :auto))
    {:ok, ban}
  end

  defp ban_until(jail, offences, now) do
    minutes =
      SiteSettings.get("jail_#{jail}_bantime") *
        Integer.pow(SiteSettings.get("jail_bantime_factor"), offences - 1)

    DateTime.add(now, min(minutes, SiteSettings.get("jail_max_ban_hours") * 60), :minute)
  end

  defp announce_ban(ban, source) do
    entry = cache_entry(ban)
    :ets.insert(Tables.bans(), entry)
    Phoenix.PubSub.broadcast(Firefly.PubSub, Tables.topic(), {:jail_ban, entry})

    :telemetry.execute([:firefly, :security, :ban], %{count: 1}, %{jail: ban.jail, source: source})

    Logger.warning("Banned #{ban.ip} until #{ban.banned_until || "forever"} (#{ban.reason})")

    Security.record("ip.ban", nil, %{jail: ban.jail, reason: ban.reason, offences: ban.offences},
      ip: ban.ip,
      user_agent: nil
    )

    Firefly.Plugins.Events.emit("ip_banned", %{
      ip: ban.ip,
      jail: ban.jail,
      reason: ban.reason,
      until: ban.banned_until && DateTime.to_iso8601(ban.banned_until)
    })
  end

  defp cache_entry(%Ban{} = ban) do
    until =
      if ban.banned_until, do: DateTime.to_unix(ban.banned_until, :millisecond), else: :infinity

    range =
      case String.split(ban.ip, "/") do
        [_address] -> nil
        [_network, "64"] -> nil
        [_network, _bits] -> IPRange.parse!(ban.ip)
      end

    {ban.ip, until, ban.jail, range}
  end

  @doc "Lifts `ban` as `admin`, staff-logged; its offences are forgotten."
  def unban(%Ban{} = ban, %User{} = admin) do
    now = DateTime.utc_now(:second)

    {:ok, ban} =
      Repo.transact(fn ->
        StaffLog.record(admin, "ip.unban", {"ban", ban.id}, %{ip: ban.ip})
        ban |> Ecto.Changeset.change(banned_until: now, offences: 0) |> Repo.update()
      end)

    :ets.delete(Tables.bans(), ban.ip)
    Phoenix.PubSub.broadcast(Firefly.PubSub, Tables.topic(), {:jail_unban, ban.ip})
    Security.record("ip.unban", nil, %{by: admin.username}, ip: ban.ip, user_agent: nil)
    Firefly.Plugins.Events.emit("ip_unbanned", %{ip: ban.ip})
    {:ok, ban}
  end

  @doc "A ban by id, or nil."
  def get_ban(id), do: Repo.get(Ban, id)

  @doc """
  Loads the bans in force into this node's cache, replacing it (at start,
  see `Firefly.Security.Jail.Tables`).
  """
  def reload(now \\ DateTime.utc_now()) do
    entries = Enum.map(active_bans(now), &cache_entry/1)
    :ets.delete_all_objects(Tables.bans())
    :ets.insert(Tables.bans(), entries)
    :ok
  end

  @doc "Forgets this node's counters and cached bans (tests)."
  def reset do
    :ets.delete_all_objects(Tables.counters())
    :ets.delete_all_objects(Tables.bans())
    :ok
  end

  @doc """
  Deletes the bans that ended longer ago than `ip_retention_days` (their
  offences are forgotten with them). Run every 10 minutes by
  `Firefly.Jobs.Periodic`. Returns how many went.
  """
  def run_cleanup(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -SiteSettings.get("ip_retention_days"), :day)
    {count, _} = Repo.delete_all(from(b in Ban, where: b.banned_until < ^cutoff))
    count
  end
end
