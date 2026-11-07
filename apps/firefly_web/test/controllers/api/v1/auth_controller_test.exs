defmodule FireflyWeb.Api.V1.AuthControllerTest do
  use FireflyWeb.ConnCase

  alias Firefly.Accounts

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        username: "admin",
        email: "admin@example.com",
        password: "tangerine-otter-galaxy"
      })

    %{user: user}
  end

  test "POST /identity returns the API token", %{conn: conn, user: user} do
    conn =
      post(conn, "/api/v1/auth/identity",
        user: %{username: "admin", password: "tangerine-otter-galaxy"}
      )

    token = json_response(conn, 200)["data"]["api_token"]
    assert {:ok, _key, %{id: id}} = Accounts.ApiKeys.authenticate(token, {127, 0, 0, 1})
    assert id == user.id
  end

  test "POST /identity never registers unknown users", %{conn: conn} do
    conn =
      post(conn, "/api/v1/auth/identity",
        user: %{username: "nobody", password: "tangerine-otter-galaxy"}
      )

    assert json_response(conn, 401)["detail"]
    refute Accounts.get_user_by_username("nobody")
  end
end
