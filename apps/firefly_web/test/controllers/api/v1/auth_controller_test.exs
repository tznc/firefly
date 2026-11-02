defmodule FireflyWeb.Api.V1.AuthControllerTest do
  use FireflyWeb.ConnCase

  alias Firefly.Accounts

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        username: "admin",
        email: "admin@example.com",
        password: "password"
      })

    %{user: user}
  end

  test "POST /identity returns the API token", %{conn: conn, user: user} do
    conn = post(conn, "/api/v1/auth/identity", user: %{username: "admin", password: "password"})
    assert json_response(conn, 200)["data"]["api_token"] == user.api_token
  end

  test "POST /identity never registers unknown users", %{conn: conn} do
    conn = post(conn, "/api/v1/auth/identity", user: %{username: "nobody", password: "password"})
    assert json_response(conn, 401)["error"]
    refute Accounts.get_user_by_username("nobody")
  end
end
