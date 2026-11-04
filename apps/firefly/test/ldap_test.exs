defmodule Firefly.LDAPTest do
  # The directory's configuration is global.
  use Firefly.DataCase, async: false

  import Firefly.Fixtures

  alias Firefly.{Groups, LDAPTestDirectory, Repo}
  alias Firefly.Accounts.{Auth, UserIdentity}
  alias Firefly.Accounts.Auth.LDAP
  alias Firefly.Accounts.Auth.LDAP.Filter

  describe "filters" do
    test "parse the RFC 4515 forms" do
      assert Filter.parse("(uid=%{username})", %{"username" => "fry"}) ==
               {:ok, :eldap.equalityMatch(~c"uid", ~c"fry")}

      assert {:ok, filter} =
               Filter.parse(
                 "(&(objectClass=user)(|(sAMAccountName=%{username})(mail=%{username}@corp))(!(cn=x*y*z))(mail=*))",
                 %{"username" => "fry"}
               )

      assert filter ==
               :eldap.and([
                 :eldap.equalityMatch(~c"objectClass", ~c"user"),
                 :eldap.or([
                   :eldap.equalityMatch(~c"sAMAccountName", ~c"fry"),
                   :eldap.equalityMatch(~c"mail", ~c"fry@corp")
                 ]),
                 :eldap.not(:eldap.substrings(~c"cn", initial: ~c"x", any: ~c"y", final: ~c"z")),
                 :eldap.present(~c"mail")
               ])

      assert Filter.parse("(cn=a\\2ab)", %{}) == {:ok, :eldap.equalityMatch(~c"cn", ~c"a*b")}
    end

    test "fill placeholders in as literal values: no LDAP injection" do
      for username <- ["*", "fry)(uid=*", "a\\2a", "x*"] do
        assert Filter.parse("(uid=%{username})", %{"username" => username}) ==
                 {:ok, :eldap.equalityMatch(~c"uid", String.to_charlist(username))}
      end
    end

    test "refuse malformed filters and unknown placeholders" do
      for template <- ["uid=x", "(uid=x", "(&)", "(uid=x))", "((uid=x))", "(uid=%{nope})"] do
        assert {:error, :invalid_filter} = Filter.parse(template, %{"username" => "fry"})
      end
    end
  end

  describe "without a directory" do
    test "is off until configured" do
      LDAPTestDirectory.configure(host: nil)
      refute LDAP.enabled?()
      refute :ldap in Auth.enabled_providers()
    end

    test "an unreachable directory is unavailable, an empty password never tried" do
      LDAPTestDirectory.configure(host: "127.0.0.1", port: 1)
      assert {:error, :unavailable} = LDAP.authenticate("fry", "fry")
      assert {:error, :invalid_credentials} = LDAP.authenticate("fry", "")
      assert {:error, :invalid_credentials} = LDAP.authenticate(" ", "x")
    end
  end

  describe "with OpenLDAP" do
    @describetag :ldap

    setup do
      LDAPTestDirectory.configure()
    end

    test "checks the password with a bind as the user's entry" do
      assert {:ok, entry} = LDAP.authenticate("fry", "fry")
      assert entry.dn == "cn=Philip J. Fry,ou=people,dc=planetexpress,dc=com"

      assert {entry.username, entry.email, entry.name} ==
               {"fry", "fry@planetexpress.com", "Philip J. Fry"}

      assert entry.uid =~ ~r/^[0-9a-f-]{36}$/
      assert entry.groups == ["ship_crew"]

      assert {:error, :invalid_credentials} = LDAP.authenticate("fry", "leela")
      assert {:error, :invalid_credentials} = LDAP.authenticate("nobody", "fry")
    end

    test "usernames can't widen the search" do
      for username <- ["*", "f*", "fry)(uid=*", "*)(|(uid=*"] do
        assert {:error, :invalid_credentials} = LDAP.authenticate(username, "fry")
      end
    end

    test "a username matching several entries logs no one in" do
      LDAPTestDirectory.configure(user_filter: "(|(uid=%{username})(objectClass=inetOrgPerson))")
      assert {:error, :invalid_credentials} = LDAP.authenticate("fry", "fry")
    end

    test "a wrong service account password makes the directory unavailable" do
      LDAPTestDirectory.configure(bind_password: "wrong")
      assert {:error, :unavailable} = LDAP.authenticate("fry", "fry")
    end

    test "LDAPS and StartTLS verify the server's certificate" do
      LDAPTestDirectory.configure(encryption: "ldaps", port: 10636)
      assert {:ok, _entry} = LDAP.authenticate("fry", "fry")

      # Self-signed, and for another name: refused once verification is on.
      LDAPTestDirectory.configure(encryption: "ldaps", port: 10636, verify: true)
      assert {:error, :unavailable} = LDAP.authenticate("fry", "fry")

      LDAPTestDirectory.configure(verify: true)
      assert {:error, :unavailable} = LDAP.authenticate("fry", "fry")
    end

    test "logs in, creating a user linked by the entry's id, with its groups" do
      {:ok, _crew} = Groups.create_role("ship_crew")
      {:ok, old} = Groups.create_role("old_crew")

      assert {:ok, user} = LDAP.login("fry", "fry")

      assert {user.username, user.email, user.name} ==
               {"fry", "fry@planetexpress.com", "Philip J. Fry"}

      assert user.confirmed_at

      assert %UserIdentity{info: %{"email" => "fry@planetexpress.com"}} =
               Repo.get_by(UserIdentity, provider: "ldap", user_id: user.id)

      roles = fn ->
        user |> Repo.preload(:roles, force: true) |> Map.get(:roles) |> Enum.map(& &1.name)
      end

      assert roles.() == ["ship_crew"]

      {:ok, _} = Groups.add_role(user, old)
      assert {:ok, again} = LDAP.login("fry", "fry")
      assert again.id == user.id
      assert roles.() == ["ship_crew"]
    end

    test "links the confirmed local account with the directory's email" do
      local = user_fixture(%{username: "philip", email: "fry@planetexpress.com"})
      assert {:ok, user} = LDAP.login("fry", "fry")
      assert user.id == local.id
    end
  end
end
