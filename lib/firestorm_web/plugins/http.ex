defmodule FirestormWeb.Plugins.HTTP do
  @moduledoc """
  The `http.fetch` host function (the `http` permission): plugins call out
  to hosts their manifest lists in `http_hosts` (`api.example.com`, or
  `*.example.com` for its subdomains), and nowhere else.

  Guards against server-side request forgery: the host name must be on the
  list; it's resolved here and every address it resolves to must be public
  (no loopback, private, link-local, carrier-grade NAT, multicast or
  reserved ranges, IPv4 or IPv6), and the request goes to that address, so a
  second lookup can't swap in an internal one (TLS is still verified against
  the host name). Redirects aren't followed. Requests time out after 5
  seconds; request bodies are at most 100 KB and responses 1 MB.

  `args`: `url`, optional `method` (GET, POST, PUT, PATCH, DELETE, HEAD),
  `headers` (an object) and `body` (text). The result is `{status, headers,
  body}`, the body as text.
  """

  import Bitwise

  @methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete,
    "HEAD" => :head
  }
  # Addresses plugins may not reach: "this network", private, loopback,
  # carrier-grade NAT, link-local, IETF and documentation ranges, benchmarking,
  # multicast and reserved; for IPv6 unspecified, loopback, unique local,
  # link-local, multicast, documentation and Teredo.
  @reserved [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 3},
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8},
    {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 32}
  ]
  @max_request 100 * 1024
  @max_response 1024 * 1024
  # Headers a plugin can't set: the connection's business.
  @reserved_headers ~w(host content-length connection transfer-encoding)

  @doc "Makes the request for a plugin allowed `hosts`."
  def fetch(hosts, %{"url" => url} = args) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- check_scheme(uri),
         :ok <- check_host(uri.host, hosts),
         {:ok, method} <- method(args["method"]),
         {:ok, headers} <- headers(args["headers"]),
         {:ok, body} <- body(args["body"]),
         {:ok, ip} <- resolve(uri.host) do
      request(method, uri, ip, headers, body)
    end
  end

  def fetch(_hosts, _args), do: {:error, "a url is required"}

  defp check_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp check_scheme(_uri), do: {:error, "only http and https URLs can be fetched"}

  @doc "Whether `host` is one of `patterns` (`*.example.com` matches subdomains)."
  def allowed?(host, patterns) when is_binary(host) do
    host = String.downcase(host)

    Enum.any?(patterns, fn
      "*." <> domain -> String.ends_with?(host, "." <> domain)
      exact -> host == exact
    end)
  end

  def allowed?(_host, _patterns), do: false

  defp check_host(host, patterns) do
    if allowed?(host, patterns),
      do: :ok,
      else: {:error, "host #{host} isn't in the plugin's http_hosts"}
  end

  defp method(nil), do: {:ok, :get}

  defp method(method) when is_binary(method) do
    case Map.fetch(@methods, String.upcase(method)) do
      {:ok, method} -> {:ok, method}
      :error -> {:error, "unsupported method #{method}"}
    end
  end

  defp method(_method), do: {:error, "invalid method"}

  defp headers(nil), do: {:ok, []}

  defp headers(headers) when is_map(headers) do
    if Enum.all?(headers, fn {key, value} -> is_binary(key) and is_binary(value) end),
      do:
        {:ok, Enum.reject(headers, fn {key, _} -> String.downcase(key) in @reserved_headers end)},
      else: {:error, "headers must be an object of text"}
  end

  defp headers(_headers), do: {:error, "headers must be an object of text"}

  defp body(nil), do: {:ok, ""}
  defp body(body) when is_binary(body) and byte_size(body) <= @max_request, do: {:ok, body}
  defp body(_body), do: {:error, "the body must be text of at most 100 KB"}

  # Every address must be public: a name that also resolves internally is
  # refused outright.
  defp resolve(host) do
    addresses =
      for family <- [:inet, :inet6],
          {:ok, ips} <- [:inet.getaddrs(String.to_charlist(host), family)],
          ip <- ips,
          do: ip

    cond do
      addresses == [] -> {:error, "#{host} doesn't resolve"}
      Enum.all?(addresses, &public?/1) -> {:ok, hd(addresses)}
      true -> {:error, "#{host} resolves to a private address"}
    end
  end

  @doc "Whether `ip` is a public address plugins may reach."
  def public?(ip) do
    if Application.get_env(:firestorm_web, __MODULE__, [])[:allow_private],
      do: true,
      else: not reserved?(ip)
  end

  # IPv4-mapped and NAT64 addresses are as public as the IPv4 they carry.
  defp reserved?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: reserved?(ipv4(high, low))
  defp reserved?({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: reserved?(ipv4(high, low))
  defp reserved?(ip), do: Enum.any?(@reserved, &in_range?(ip, &1))

  defp ipv4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp in_range?(ip, {network, bits}) when tuple_size(ip) == tuple_size(network) do
    size = tuple_size(ip) * if(tuple_size(ip) == 4, do: 8, else: 16)
    shift = size - bits
    to_integer(ip) >>> shift == to_integer(network) >>> shift
  end

  defp in_range?(_ip, _range), do: false

  defp to_integer({_, _, _, _} = ip),
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 8 ||| &1))

  defp to_integer(ip), do: ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 16 ||| &1))

  # The URL with the resolved address in place of the host name.
  defp target(uri, ip) do
    port = uri.port || if(uri.scheme == "https", do: 443, else: 80)
    address = ip |> :inet.ntoa() |> to_string()
    address = if tuple_size(ip) == 8, do: "[#{address}]", else: address
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    "#{uri.scheme}://#{address}:#{port}#{path}"
  end

  defp request(method, uri, ip, headers, body) do
    target = target(uri, ip)
    host_header = if uri.port, do: "#{uri.host}:#{uri.port}", else: uri.host

    options = [
      connect_timeout: 3_000,
      recv_timeout: 5_000,
      follow_redirect: false,
      pool: false,
      max_body_size: @max_response,
      ssl_options: [server_name_indication: String.to_charlist(uri.host)]
    ]

    case :hackney.request(method, target, [{"host", host_header} | headers], body, options) do
      {:ok, status, response_headers, body} -> response(status, response_headers, body)
      {:ok, status, response_headers} -> response(status, response_headers, "")
      {:error, :body_too_large} -> {:error, "the response is over 1 MB"}
      {:error, reason} -> {:error, "request failed: #{inspect(reason)}"}
    end
  end

  defp response(status, headers, body) do
    if String.valid?(body),
      do: {:ok, %{status: status, headers: Map.new(headers), body: body}},
      else:
        {:ok,
         %{status: status, headers: Map.new(headers), body: Base.encode64(body), base64: true}}
  end
end
