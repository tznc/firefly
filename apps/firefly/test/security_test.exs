defmodule Firefly.SecurityTest do
  use Firefly.DataCase, async: true

  import Firefly.Fixtures

  alias Firefly.{Accounts, Repo, Security, SiteSettings}
  alias Firefly.Accounts.{ApiKeys, Passkeys, TwoFactor}
  alias Firefly.Moderation.{Akismet, Penalties}
  alias Firefly.Security.Event

  defp kinds(user), do: user |> Security.for_user() |> Enum.map(& &1.kind)

  describe "the log" do
    test "records events with the current request's client" do
      user = user_fixture()
      Akismet.put_client(%{ip: "203.0.113.9", user_agent: "Firefox"})

      :ok = Security.record("login.success", user, %{method: "password"})

      assert [%Event{kind: "login.success", ip: "203.0.113.9", user_agent: "Firefox"} = event] =
               Security.for_user(user)

      assert event.details == %{"method" => "password"}

      :ok = Security.record("ip.ban", nil, %{}, ip: {198, 51, 100, 1}, user_agent: nil)

      assert [%{ip: "198.51.100.1", user_agent: nil}] =
               Security.list(%{"kind" => "ip.ban"}).entries
    end

    test "failed logins go to the account named, if there is one" do
      user = user_fixture()
      :ok = Security.login_failed("login.failure", user.username, %{method: "password"})
      :ok = Security.login_failed("login.failure", "nobody-#{user.id}", %{method: "password"})

      assert [%{details: %{"username" => username}}] = Security.for_user(user)
      assert username == user.username

      assert %{entries: [%{user_id: nil}, %{user_id: id}]} =
               Security.list(%{"kind" => "login.failure"})

      assert id == user.id
    end

    test "staff filter by kind and by username or address" do
      alice = user_fixture()
      bob = user_fixture()
      Security.record("login.success", alice, %{}, ip: "192.0.2.10")
      Security.record("login.failure", bob, %{}, ip: "192.0.2.20")
      Security.record("login.success", bob, %{}, ip: "2001:db8::1")

      ids = fn filters -> Enum.map(Security.list(filters).entries, & &1.user_id) end

      assert ids.(%{"kind" => "login.failure"}) == [bob.id]
      assert ids.(%{"q" => String.upcase(alice.username)}) == [alice.id]
      assert ids.(%{"q" => "192.0.2."}) |> Enum.sort() == Enum.sort([alice.id, bob.id])
      assert ids.(%{"q" => "2001:db8"}) == [bob.id]
      # LIKE wildcards are literal.
      assert ids.(%{"q" => "%"}) == []
    end

    test "nothing is recorded for an unknown kind" do
      assert_raise FunctionClauseError, fn -> Security.record("made.up", nil) end
    end
  end

  describe "what goes in the log" do
    test "two-factor, passkey and password changes" do
      user = user_fixture()
      secret = TwoFactor.new_secret()
      {:ok, _codes} = TwoFactor.enable_totp(user, secret, NimbleTOTP.verification_code(secret))
      {:ok, _codes} = TwoFactor.regenerate_backup_codes(user)
      {:ok, _} = TwoFactor.reset(user, admin_fixture())
      {:ok, _user} = Accounts.reset_user_password(user, %{password: "a long new password"})

      assert kinds(user) ==
               ~w(password.reset two_factor.reset two_factor.backup_codes two_factor.enable)
    end

    test "passkeys" do
      user = user_fixture()

      {:ok, passkey} =
        Passkeys.add(
          user,
          %{
            credential_id: "cred-#{user.id}",
            public_key: :erlang.term_to_binary(%{}),
            sign_count: 0
          },
          "Laptop"
        )

      {:ok, _} = Accounts.reset_user_password(user, %{password: "a long new password"})
      :ok = Passkeys.delete(Repo.reload(user), passkey.id)

      assert [
               %{kind: "passkey.remove"},
               _reset,
               %{kind: "passkey.add", details: %{"name" => "Laptop"}}
             ] =
               Security.for_user(user)
    end

    test "API keys: created, first used from each address, revoked" do
      user = user_fixture()
      {:ok, key, token} = ApiKeys.create(user, %{name: "script", scopes: ["read"]})
      {:ok, _key, _user} = ApiKeys.authenticate(token, {192, 0, 2, 1})
      {:ok, _key, _user} = ApiKeys.authenticate(token, {192, 0, 2, 1})
      {:ok, _key, _user} = ApiKeys.authenticate(token, {192, 0, 2, 2})
      {:ok, _key} = ApiKeys.revoke(Repo.reload(key), user)

      assert kinds(user) == ~w(api_key.revoke api_key.use api_key.use api_key.create)

      assert ["192.0.2.2", "192.0.2.1"] =
               user
               |> Security.for_user()
               |> Enum.filter(&(&1.kind == "api_key.use"))
               |> Enum.map(& &1.ip)
    end

    test "suspensions and silences, without the staff member's address" do
      user = user_fixture()
      admin = admin_fixture()
      Akismet.put_client(%{ip: "203.0.113.50"})

      {:ok, user} =
        Penalties.penalize(:suspend, user, admin, %{"duration" => "1d", "reason" => "spam"})

      {:ok, _user} = Penalties.lift(:suspend, user, admin)

      assert [%{kind: "account.unsuspend", ip: nil}, %{kind: "account.suspend", ip: nil}] =
               Security.for_user(user)
    end
  end

  describe "IP retention" do
    test "anonymizes addresses to their network" do
      assert Security.anonymize_ip("203.0.113.77") == "203.0.113.0"
      assert Security.anonymize_ip("2001:db8:abcd:12:1:2:3:4") == "2001:db8:abcd::"
      assert Security.anonymize_ip("unknown") == "unknown"
    end

    test "truncates or deletes stored addresses older than the setting" do
      admin = admin_fixture()
      user = user_fixture()
      {:ok, _} = SiteSettings.update(%{"ip_retention_days" => "30"}, admin)
      old = DateTime.add(DateTime.utc_now(), -31, :day)
      recent = DateTime.add(DateTime.utc_now(), -29, :day)

      event = fn ip, at ->
        Repo.insert!(%Event{kind: "login.success", user_id: user.id, ip: ip, inserted_at: at})
      end

      old_v4 = event.("203.0.113.77", old)
      old_v6 = event.("2001:db8:abcd:12::1", old)
      odd = event.("unknown", old)
      fresh = event.("203.0.113.78", recent)

      Repo.insert_all("user_ips", [
        %{user_id: user.id, ip: "198.51.100.1", first_seen_at: old, last_seen_at: old},
        %{user_id: user.id, ip: "198.51.100.2", first_seen_at: old, last_seen_at: recent}
      ])

      {:ok, key, _token} = ApiKeys.create(user, %{name: "k", scopes: ["read"]})

      key
      |> Ecto.Changeset.change(
        last_used_ip: "192.0.2.55",
        last_used_at: DateTime.truncate(old, :second)
      )
      |> Repo.update!()

      Repo.insert_all("akismet_checks", [
        %{
          kind: "post",
          subject_id: 1,
          user_id: user.id,
          spam: false,
          status: "clean",
          params: %{"user_ip" => "192.0.2.66", "user_agent" => "UA"},
          inserted_at: DateTime.truncate(old, :second),
          updated_at: DateTime.truncate(old, :second)
        }
      ])

      counts = Security.run_retention()
      assert counts["security_events"] == 2
      assert counts["user_ips"] == 1

      assert Repo.reload(old_v4).ip == "203.0.113.0"
      assert Repo.reload(old_v6).ip == "2001:db8:abcd::"
      assert Repo.reload(odd).ip == "unknown"
      assert Repo.reload(fresh).ip == "203.0.113.78"
      assert Repo.all(from(i in "user_ips", select: i.ip)) == ["198.51.100.2"]
      assert Repo.reload(key).last_used_ip == "192.0.2.0"

      assert [%{"user_ip" => "192.0.2.0", "user_agent" => "UA"}] =
               Repo.all(from(c in "akismet_checks", select: c.params))

      # Nothing left to change the second time.
      assert Security.run_retention() |> Map.values() |> Enum.sum() == 0
    end
  end
end
