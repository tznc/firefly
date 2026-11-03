defmodule FireflyWeb.ClientIP do
  @moduledoc """
  The client's IP address, for per-IP rate limits.

  Behind a reverse proxy or load balancer every request comes from the
  proxy, so the client is read from `X-Forwarded-For` instead, but only
  when the request comes from a trusted proxy (anyone can send that
  header). Trusted proxies are addresses or CIDR ranges in the
  `FIREFLY_TRUSTED_PROXIES` environment variable, comma-separated, e.g.
  `10.0.0.0/8,fd00::/8` (see `Firefly.IPRange`). With none configured (the default) the socket's
  peer address is used and the header is ignored.

  The header is read right to left: each hop appends the address it got
  the request from, so the first address that isn't a trusted proxy is the
  client. Earlier entries could have been made up by the client.

  As a plug it rewrites `conn.remote_ip`. LiveViews call `from_socket/1`,
  which needs `:peer_data` and `:x_headers` in the socket's `connect_info`.
  """

  @behaviour Plug

  alias Firefly.IPRange

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    %{
      conn
      | remote_ip: resolve(conn.remote_ip, Plug.Conn.get_req_header(conn, "x-forwarded-for"))
    }
  end

  @doc """
  The client IP of a LiveView's connection, or `"unknown"` (e.g. on the
  static render, which has no connect info).
  """
  def from_socket(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} ->
        headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
        resolve(address, for({"x-forwarded-for", value} <- headers, do: value))

      _unknown ->
        "unknown"
    end
  end

  @doc """
  The client address given the peer's `address` and the values of its
  `X-Forwarded-For` headers.
  """
  def resolve(address, forwarded_for) do
    case trusted_proxies() do
      [] ->
        address

      proxies ->
        if trusted?(address, proxies),
          do: forwarded(forwarded_for, proxies, address),
          else: address
    end
  end

  # Right to left: the first untrusted hop is the client. If every hop is
  # a trusted proxy, the leftmost one is as close as we get.
  defp forwarded(values, proxies, fallback) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&IPRange.address(String.trim(&1)))
    |> Enum.reverse()
    |> Enum.reduce_while(fallback, fn
      nil, last ->
        {:halt, last}

      address, _last ->
        if trusted?(address, proxies), do: {:cont, address}, else: {:halt, address}
    end)
  end

  defp trusted?(address, proxies), do: IPRange.member?(address, proxies)

  @doc "The configured trusted proxies, as parsed `Firefly.IPRange` ranges."
  def trusted_proxies do
    :firefly_web
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:trusted_proxies, [])
    |> Enum.map(&IPRange.parse!/1)
  end
end
