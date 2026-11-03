defmodule FireflyWeb.Plugs.ApiCurrentUser do
  @moduledoc """
  Authenticates requests by API key (`Authorization: Bearer <key>`; see
  `Firefly.Accounts.ApiKeys`), assigning `:current_user` and `:api_key`.
  A global key acts as the user in the `Api-Username` header.

  A request over the key's rate limit is refused (`429`). An unknown,
  revoked or expired key, or one used from an address it doesn't allow,
  is refused (`401`/`403`) with `strict: true` (the JSON API); otherwise
  (MCP, plugin endpoints) the request just goes on without a user.
  """

  import Plug.Conn
  alias Firefly.Accounts.ApiKeys
  alias FireflyWeb.Api.Problem

  def init(opts), do: Keyword.get(opts, :strict, false)

  def call(conn, strict?) do
    case token(conn) do
      nil ->
        conn

      token ->
        username = conn |> get_req_header("api-username") |> List.first()

        case ApiKeys.authenticate(token, conn.remote_ip, username) do
          {:ok, key, user} ->
            conn |> assign(:current_user, user) |> assign(:api_key, key)

          {:error, :rate_limited} ->
            conn
            |> put_resp_header("retry-after", "60")
            |> Problem.send(429, Firefly.RateLimit.message())

          {:error, reason} when strict? ->
            refuse(conn, reason)

          {:error, _reason} ->
            conn
        end
    end
  end

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      # Older clients sent the bare token.
      [token | _] -> String.trim(token)
      [] -> nil
    end
  end

  defp refuse(conn, :ip_not_allowed),
    do: Problem.send(conn, 403, "This API key can't be used from this address.")

  defp refuse(conn, :no_user),
    do: Problem.send(conn, 401, "The Api-Username header names no user this key may act as.")

  defp refuse(conn, _invalid) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="firefly", error="invalid_token"))
    |> Problem.send(401, "The API key is invalid, revoked or expired.")
  end
end
