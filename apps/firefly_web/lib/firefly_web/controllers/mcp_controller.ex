defmodule FireflyWeb.MCPController do
  @moduledoc """
  The MCP server's Streamable HTTP endpoint, `/mcp` (see
  `Firefly.AI.MCP`): each POST carries one JSON-RPC message and gets its
  response as JSON (`202 Accepted` for notifications and responses). The
  server keeps no sessions and offers no server-sent event stream, so GET
  and DELETE are `405`.

  Off (`404`) unless the `mcp_enabled` site setting is on. Requests need a
  member's API token (`Authorization: Bearer <token>`, `401` otherwise),
  are rate limited per member (the `:mcp` bucket, `429`), refuse other
  sites' browser pages (an `Origin` header that isn't this site's, `403`,
  against DNS rebinding) and unknown `MCP-Protocol-Version` headers (`400`).
  """
  use FireflyWeb, :controller

  alias Firefly.{RateLimit, SiteSettings}
  alias Firefly.AI.MCP

  plug(:enabled)
  plug(:same_origin)
  plug(:authenticated when action == :post)

  def post(conn, _params) do
    with :ok <- protocol_version(conn),
         :ok <- RateLimit.check(:mcp, conn.assigns.current_user.id) do
      case MCP.handle(message(conn), conn.assigns.current_user) do
        {:reply, response} -> json(conn, response)
        :noreply -> send_resp(conn, 202, "")
      end
    else
      {:error, :rate_limited} ->
        conn |> put_status(429) |> json(MCP.error(nil, -32_000, RateLimit.message()))

      {:error, :version} ->
        conn
        |> put_status(400)
        |> json(MCP.error(nil, -32_600, "Unsupported MCP-Protocol-Version"))
    end
  end

  def unsupported(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  # Plug parsed the JSON body into params: a single object arrives as
  # itself, anything else (a batch) under "_json".
  defp message(%{body_params: %{"_json" => other}}), do: other
  defp message(%{body_params: %Plug.Conn.Unfetched{}}), do: nil
  defp message(%{body_params: params}), do: params

  defp protocol_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> :ok
      [version | _] -> if version in MCP.versions(), do: :ok, else: {:error, :version}
    end
  end

  defp enabled(conn, _opts) do
    if SiteSettings.get("mcp_enabled"),
      do: conn,
      else: conn |> send_resp(404, "") |> halt()
  end

  defp same_origin(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin | _] ->
        if origin == FireflyWeb.Endpoint.url(),
          do: conn,
          else: conn |> send_resp(403, "") |> halt()
    end
  end

  defp authenticated(%{assigns: %{current_user: %{}}} = conn, _opts), do: conn

  defp authenticated(conn, _opts) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="firefly"))
    |> put_status(401)
    |> json(MCP.error(nil, -32_001, "An API token is required (Authorization: Bearer <token>)."))
    |> halt()
  end
end
