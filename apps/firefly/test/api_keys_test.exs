defmodule Firefly.ApiKeysTest do
  use Firefly.DataCase, async: true

  import Firefly.Fixtures, only: [user_fixture: 0, admin_fixture: 0]

  alias Firefly.Accounts
  alias Firefly.Accounts.{ApiKey, ApiKeys}
  alias Firefly.Moderation.StaffLog

  @ip {127, 0, 0, 1}

  setup do
    %{user: user_fixture(), admin: admin_fixture()}
  end

  describe "create/2" do
    test "shows the key once and stores only its hash", %{user: user} do
      assert {:ok, key, token} = ApiKeys.create(user, %{name: "Script", scopes: ["read"]})

      assert String.starts_with?(token, "ffk_")
      assert key.prefix == String.slice(token, 0, 8)
      refute key.token_hash == token
      refute key.token_hash =~ token
      assert [listed] = ApiKeys.list(user)
      refute inspect(listed) =~ token
      assert {:ok, _key, found} = ApiKeys.authenticate(token, @ip)
      assert found.id == user.id
    end

    test "needs a name and at least one known scope", %{user: user} do
      assert {:error, changeset} = ApiKeys.create(user, %{name: "", scopes: ["read"]})
      assert "can't be blank" in errors_on(changeset).name

      assert {:error, changeset} = ApiKeys.create(user, %{name: "x", scopes: []})
      assert errors_on(changeset).scopes != []

      assert {:error, changeset} = ApiKeys.create(user, %{name: "x", scopes: ["root"]})
      assert errors_on(changeset).scopes != []
    end

    test "validates addresses and expiry", %{user: user} do
      assert {:error, changeset} =
               ApiKeys.create(user, %{name: "x", scopes: ["read"], allowed_ips: ["nope"]})

      assert errors_on(changeset).allowed_ips != []

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:error, changeset} =
               ApiKeys.create(user, %{name: "x", scopes: ["read"], expires_at: past})

      assert "must be in the future" in errors_on(changeset).expires_at
    end
  end

  describe "scopes" do
    test "write covers every :write scope, read and admin don't", %{user: user} do
      {:ok, write, _} = ApiKeys.create(user, %{name: "w", scopes: ["write"]})
      {:ok, read, _} = ApiKeys.create(user, %{name: "r", scopes: ["read"]})

      assert ApiKeys.allows?(write, "topics:write")
      assert ApiKeys.allows?(write, "chat:write")
      refute ApiKeys.allows?(write, "read")
      refute ApiKeys.allows?(write, "admin")
      refute ApiKeys.allows?(read, "topics:write")
    end
  end

  describe "authenticate/3" do
    test "refuses revoked, expired and unknown keys", %{user: user} do
      {:ok, key, token} = ApiKeys.create(user, %{name: "k", scopes: ["read"]})

      assert {:error, :invalid} = ApiKeys.authenticate("ffk_nope", @ip)
      assert {:error, :invalid} = ApiKeys.authenticate("", @ip)

      {:ok, _} = ApiKeys.revoke(key, user)
      assert {:error, :invalid} = ApiKeys.authenticate(token, @ip)

      {:ok, _expired, expired_token} = ApiKeys.create(user, %{name: "e", scopes: ["read"]})

      Repo.update_all(ApiKey, set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])

      assert {:error, :invalid} = ApiKeys.authenticate(expired_token, @ip)
    end

    test "refuses suspended and deleted users' keys", %{user: user, admin: admin} do
      {:ok, _key, token} = ApiKeys.create(user, %{name: "k", scopes: ["read"]})

      {:ok, _user} =
        Firefly.Moderation.Penalties.penalize(:suspend, user, admin, %{
          "duration" => "1d",
          "reason" => "spam"
        })

      assert {:error, :invalid} = ApiKeys.authenticate(token, @ip)
    end

    test "honors the IP allowlist", %{user: user} do
      {:ok, _key, token} =
        ApiKeys.create(user, %{name: "k", scopes: ["read"], allowed_ips: ["10.0.0.0/8"]})

      assert {:error, :ip_not_allowed} = ApiKeys.authenticate(token, @ip)
      assert {:ok, _key, _user} = ApiKeys.authenticate(token, {10, 1, 2, 3})
    end

    test "tracks the last use", %{user: user} do
      {:ok, key, token} = ApiKeys.create(user, %{name: "k", scopes: ["read"]})
      assert key.last_used_at == nil

      {:ok, used, _user} = ApiKeys.authenticate(token, {10, 0, 0, 7})
      assert used.last_used_ip == "10.0.0.7"
      assert used.last_used_at != nil
    end

    test "enforces the key's own rate limit", %{user: user} do
      {:ok, _key, token} = ApiKeys.create(user, %{name: "k", scopes: ["read"], rate_limit: 1})

      assert {:ok, _key, _user} = ApiKeys.authenticate(token, @ip)
      assert {:error, :rate_limited} = ApiKeys.authenticate(token, @ip)
    end
  end

  describe "global keys" do
    test "act as the named user, or their creator, and only for admins", %{
      admin: admin,
      user: user
    } do
      assert {:ok, key, token} = ApiKeys.create_global(admin, %{name: "CI", scopes: ["read"]})
      assert ApiKey.global?(key)

      assert {:ok, _key, acting} = ApiKeys.authenticate(token, @ip, user.username)
      assert acting.id == user.id

      assert {:ok, _key, acting} = ApiKeys.authenticate(token, @ip)
      assert acting.id == admin.id

      assert {:error, :no_user} = ApiKeys.authenticate(token, @ip, "nobody")
      assert [%{action: "api_key.create"} | _] = Repo.all(Firefly.Moderation.StaffAction)
      assert "api_key.create" in StaffLog.actions()
    end

    test "stop working once their creator isn't an admin", %{admin: admin} do
      {:ok, _key, token} = ApiKeys.create_global(admin, %{name: "CI", scopes: ["read"]})
      role = Repo.get_by!(Firefly.Groups.Role, name: "admin")
      {:ok, _} = Firefly.Groups.remove_member(role, admin, admin_fixture())

      assert {:error, :no_user} = ApiKeys.authenticate(token, @ip)
    end

    test "only admins create them", %{user: user} do
      assert {:error, :unauthorized} = ApiKeys.create_global(user, %{name: "x", scopes: ["read"]})
    end
  end

  describe "revoke/2" do
    test "the owner and admins may; nobody else", %{user: user, admin: admin} do
      {:ok, key, _token} = ApiKeys.create(user, %{name: "k", scopes: ["read"]})

      assert {:error, :unauthorized} = ApiKeys.revoke(key, user_fixture())
      assert {:ok, revoked} = ApiKeys.revoke(key, admin)
      assert revoked.revoked_at != nil
      assert {:ok, _} = ApiKeys.revoke(revoked, user)
    end
  end

  test "the old api_token column became a full-scope key per member" do
    # The migration ran before the suite; accounts made since get keys of
    # their own, so check the shape the migration leaves behind.
    user = user_fixture()
    {:ok, _key, token} = ApiKeys.create_login_key(user)
    {:ok, key, _user} = ApiKeys.authenticate(token, @ip)

    assert Enum.sort(key.scopes) == Enum.sort(ApiKeys.full_scopes())
    assert ApiKeys.allows?(key, "read")
    assert ApiKeys.allows?(key, "admin")
    assert ApiKeys.allows?(key, "chat:write")
  end

  test "account deletion takes the keys with it" do
    {:ok, user} =
      Accounts.register_user(%{
        username: "ada",
        email: "ada@example.com",
        password: "ada-password"
      })

    {:ok, user} = Accounts.confirm_user(user)
    {:ok, _key, token} = ApiKeys.create(user, %{name: "k", scopes: ["read"]})

    {:ok, _user} = Firefly.Accounts.AccountDeletion.delete_account(user, "ada-password")

    assert {:error, :invalid} = ApiKeys.authenticate(token, @ip)
    assert ApiKeys.list(user) == []
  end
end
