defmodule Firefly.JailTest do
  # The jail's ETS tables are per node, shared by every test.
  use Firefly.DataCase, async: false

  import Firefly.Fixtures

  alias Firefly.{Repo, Security, SiteSettings}
  alias Firefly.Moderation.StaffAction
  alias Firefly.Security.{Ban, Jail}
  alias Firefly.Security.Jail.Tables

  setup do
    config = Application.get_env(:firefly, Jail)
    Application.put_env(:firefly, Jail, enabled: true, trusted_proxies: ["10.9.0.0/16"])
    Jail.reset()

    on_exit(fn ->
      Application.put_env(:firefly, Jail, config)
      Jail.reset()
    end)

    {:ok, admin: admin_fixture()}
  end

  defp set(settings, admin), do: {:ok, _} = SiteSettings.update(settings, admin)

  defp signals(ip, kind, n, now \\ DateTime.utc_now()),
    do: for(_ <- 1..n, do: Jail.signal(ip, kind, %{}, now))

  test "an address is banned once its points reach the jail's threshold" do
    assert Enum.all?(signals("203.0.113.5", "login_failure", 9), &(&1 == :ok))
    refute Jail.banned("203.0.113.5")

    assert {:banned, %Ban{ip: "203.0.113.5", jail: "auth", offences: 1} = ban} =
             Jail.signal("203.0.113.5", "login_failure")

    assert %{key: "203.0.113.5", jail: "auth", until: until} = Jail.banned({203, 0, 113, 5})
    assert_in_delta DateTime.diff(until, DateTime.utc_now()), 30 * 60, 5
    assert DateTime.compare(ban.banned_until, DateTime.utc_now()) == :gt
    refute Jail.banned("203.0.113.6")

    # Every ban is in the security log.
    assert [%{kind: "ip.ban", ip: "203.0.113.5"}] = Security.list(%{"kind" => "ip.ban"}).entries
  end

  test "points count within the find time only", %{admin: admin} do
    set(%{"jail_auth_findtime" => "10"}, admin)
    t0 = DateTime.utc_now()
    signals("203.0.113.7", "login_failure", 9, t0)

    # Eleven minutes on, the first nine have left the window.
    later = DateTime.add(t0, 11, :minute)
    assert Enum.all?(signals("203.0.113.7", "login_failure", 9, later), &(&1 == :ok))
    assert {:banned, _} = Jail.signal("203.0.113.7", "login_failure", %{}, later)
  end

  test "signals weigh differently and jails count apart" do
    # Exploit probes count 10 each in the probe jail (threshold 30).
    assert [:ok, :ok, {:banned, %{jail: "probe"}}] = signals("198.51.100.9", "exploit_probe", 3)

    signals("198.51.100.10", "not_found", 29)
    signals("198.51.100.10", "login_failure", 9)
    refute Jail.banned("198.51.100.10")
  end

  test "repeat offenders are banned longer each time, up to the maximum", %{admin: admin} do
    set(
      %{"jail_spam_threshold" => "1", "jail_spam_bantime" => "60", "jail_max_ban_hours" => "3"},
      admin
    )

    now = DateTime.utc_now(:second)

    lengths =
      for n <- 0..3 do
        at = DateTime.add(now, n * 10, :hour)
        {:banned, ban} = Jail.signal("192.0.2.44", "akismet_spam", %{}, at)
        DateTime.diff(ban.banned_until, at, :minute)
      end

    assert lengths == [60, 120, 180, 180]
    assert Repo.get_by!(Ban, ip: "192.0.2.44").offences == 4
  end

  test "IPv6 addresses are banned by their /64, or one by one", %{admin: admin} do
    signals("2001:db8:1:2::1", "login_failure", 9)

    assert {:banned, %{ip: "2001:db8:1:2::/64"}} =
             Jail.signal("2001:db8:1:2::abcd", "login_failure", %{})

    assert Jail.banned("2001:db8:1:2:ffff::9")
    refute Jail.banned("2001:db8:1:3::1")

    set(%{"jail_ipv6_prefix" => "128"}, admin)
    signals("2001:db8:9::1", "login_failure", 9)
    signals("2001:db8:9::2", "login_failure", 9)
    refute Jail.banned("2001:db8:9::1")
  end

  test "the allowlist and trusted proxies are never banned", %{admin: admin} do
    set(%{"jail_allowlist" => "192.0.2.0/24"}, admin)
    assert Enum.all?(signals("192.0.2.200", "exploit_probe", 5), &(&1 == :ok))
    assert Enum.all?(signals("10.9.3.4", "exploit_probe", 5), &(&1 == :ok))
    refute Jail.banned("192.0.2.200")
    refute Jail.banned("10.9.3.4")

    assert {:error, _} = Jail.ban("10.9.0.1", admin)
  end

  test "nothing counts while the setting is off", %{admin: admin} do
    set(%{"jail_enabled" => "false"}, admin)
    assert Enum.all?(signals("203.0.113.99", "exploit_probe", 5), &(&1 == :ok))
    assert :ets.tab2list(Tables.counters()) == []
  end

  test "staff ban and unban addresses and ranges, staff-logged", %{admin: admin} do
    assert {:error, "That isn't an IP address or range."} = Jail.ban("nope", admin)
    assert {:ok, ban} = Jail.ban("198.51.100.77/24", admin, minutes: 60, reason: "botnet")
    assert ban.ip == "198.51.100.0/24"
    assert ban.jail == "manual"
    assert Jail.banned("198.51.100.3")
    refute Jail.banned("198.51.101.3")

    {:ok, forever} = Jail.ban("192.0.2.1", admin)
    assert forever.banned_until == nil
    assert %{until: nil} = Jail.banned("192.0.2.1")

    assert {:ok, _} = Jail.unban(ban, admin)
    refute Jail.banned("198.51.100.3")
    assert Repo.reload(ban).offences == 0

    assert ~w(ip.ban ip.ban ip.unban) ==
             Repo.all(
               from(a in StaffAction,
                 where: a.actor_id == ^admin.id,
                 order_by: a.id,
                 select: a.action
               )
             )

    assert [%{ip: "192.0.2.1"}] = Jail.active_bans()
  end

  test "bans reach every node's cache through PubSub" do
    until = System.system_time(:millisecond) + 60_000

    # What another node broadcasts when it bans and unbans.
    Phoenix.PubSub.broadcast(
      Firefly.PubSub,
      Tables.topic(),
      {:jail_ban, {"203.0.113.200", until, "auth", nil}}
    )

    :sys.get_state(Tables)
    assert %{jail: "auth"} = Jail.banned("203.0.113.200")

    Phoenix.PubSub.broadcast(Firefly.PubSub, Tables.topic(), {:jail_unban, "203.0.113.200"})
    :sys.get_state(Tables)
    refute Jail.banned("203.0.113.200")
  end

  test "bans survive a restart: the cache loads them from the database" do
    Repo.insert!(%Ban{
      ip: "203.0.113.50",
      jail: "auth",
      banned_until: DateTime.add(DateTime.utc_now(:second), 3600)
    })

    Repo.insert!(%Ban{
      ip: "203.0.113.51",
      jail: "auth",
      banned_until: DateTime.add(DateTime.utc_now(:second), -60)
    })

    refute Jail.banned("203.0.113.50")

    :ok = Jail.reload()
    assert Jail.banned("203.0.113.50")
    refute Jail.banned("203.0.113.51")
  end

  test "ended bans are deleted after the IP retention period", %{admin: admin} do
    set(%{"ip_retention_days" => "30"}, admin)
    now = DateTime.utc_now(:second)

    old =
      Repo.insert!(%Ban{
        ip: "192.0.2.80",
        jail: "auth",
        banned_until: DateTime.add(now, -31, :day)
      })

    recent =
      Repo.insert!(%Ban{
        ip: "192.0.2.81",
        jail: "auth",
        banned_until: DateTime.add(now, -29, :day)
      })

    forever = Repo.insert!(%Ban{ip: "192.0.2.82", jail: "manual"})

    assert Jail.run_cleanup() == 1
    refute Repo.reload(old)
    assert Repo.reload(recent)
    assert Repo.reload(forever)
  end

  test "signals and bans are counted for metrics, without the address" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:firefly, :security, :signal],
        [:firefly, :security, :ban]
      ])

    signals("203.0.113.120", "exploit_probe", 3)

    assert_received {[:firefly, :security, :signal], ^ref, %{count: 1, points: 10},
                     %{jail: "probe", kind: "exploit_probe"} = meta}

    refute Map.has_key?(meta, :ip)

    assert_received {[:firefly, :security, :ban], ^ref, %{count: 1},
                     %{jail: "probe", source: :auto}}
  end

  test "failed logins and rate limits feed the jail from the current client" do
    Firefly.Moderation.Akismet.put_client(%{ip: "203.0.113.140"})
    for _ <- 1..10, do: Security.login_failed("login.failure", "nobody", %{})
    assert Jail.banned("203.0.113.140")
  end

  test "offenders are listed closest to a ban first" do
    signals("203.0.113.160", "login_failure", 8)
    signals("203.0.113.161", "not_found", 3)

    assert [
             %{key: "203.0.113.160", jail: "auth", points: 8, threshold: 10},
             %{key: "203.0.113.161"}
           ] =
             Jail.offenders()
  end
end
