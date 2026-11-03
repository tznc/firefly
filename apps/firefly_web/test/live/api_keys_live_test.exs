defmodule FireflyWeb.ApiKeysLiveTest do
  use FireflyWeb.ConnCase, async: true

  alias Firefly.Accounts.ApiKeys

  describe "Settings > API keys" do
    test "creates a key, shows it once, then revokes it", %{conn: conn} do
      user = user_fixture()

      session =
        conn
        |> log_in_as(user)
        |> visit(~p"/settings/api-keys")
        |> assert_has("#api-keys-empty", text: "No API keys yet")
        |> fill_in("Name", with: "My script")
        |> click_button("Create key")
        |> assert_has("#new-api-key", text: "Copy your new key now")

      assert [key] = ApiKeys.list(user)
      assert key.name == "My script"
      assert key.scopes == ["read"]

      session
      |> assert_has("#api-key-#{key.id}", text: "My script")
      |> click_button("Revoke My script")
      |> assert_has("#api-key-#{key.id}", text: "Revoked")

      assert [%{revoked_at: revoked_at}] = ApiKeys.list(user)
      assert revoked_at != nil
    end

    test "shows the key's validation errors", %{conn: conn} do
      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/settings/api-keys")
      |> fill_in("Name", with: "Bad addresses")
      |> fill_in("Allowed addresses (optional: addresses or CIDR ranges, one per line)",
        with: "nope"
      )
      |> click_button("Create key")
      |> assert_has("#api-key-form", text: "isn't an address or CIDR range")
    end

    test "members only see their own keys", %{conn: conn} do
      mine = user_fixture()
      {:ok, _key, _token} = ApiKeys.create(mine, %{name: "Mine", scopes: ["read"]})

      {:ok, _key, _token} =
        ApiKeys.create(user_fixture(), %{name: "Someone else's", scopes: ["read"]})

      conn
      |> log_in_as(mine)
      |> visit(~p"/settings/api-keys")
      |> assert_has("#api-keys-list", text: "Mine")
      |> refute_has("#api-keys-list", text: "Someone else's")
    end
  end

  describe "/staff/api-keys" do
    test "admins see every key and create global ones", %{conn: conn} do
      admin = admin_fixture()
      member = user_fixture()
      {:ok, key, _token} = ApiKeys.create(member, %{name: "Member's key", scopes: ["read"]})

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/api-keys")
      |> assert_has("#api-key-#{key.id}", text: "@#{member.username}")
      |> fill_in("Name", with: "CI")
      |> check("Global key: acts as the user named in the Api-Username header (default: you)")
      |> click_button("Create key")
      |> assert_has("#new-api-key", text: "Copy your new key now")
      |> assert_has("#api-keys-list", text: "Global (by @#{admin.username})")

      assert Enum.any?(ApiKeys.list_all(), &(&1.name == "CI" and is_nil(&1.user_id)))
    end

    test "members can't open it", %{conn: conn} do
      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/staff/api-keys")
      |> assert_path(~p"/")
      |> assert_has("#flash-error", text: "not allowed")
    end
  end
end
