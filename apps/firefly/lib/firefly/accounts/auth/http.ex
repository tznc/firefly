defmodule Firefly.Accounts.Auth.HTTP do
  @moduledoc """
  HTTP for login providers' back-channel requests (OpenID Connect
  discovery, signing keys, tokens, user info; SAML metadata). Connecting times out
  after 5 seconds, reading after 10; responses over 1 MB are refused.
  """

  @max_body 1_000_000
  @options [connect_timeout: 5_000, recv_timeout: 10_000, pool: false, max_body: @max_body]

  @doc "GETs `url` and decodes its JSON object: `{:ok, map}` or `{:error, reason}`."
  def get_json(url, headers \\ []) do
    with {:ok, body} <- request(:get, url, [{"accept", "application/json"} | headers], ""),
         do: decode(body)
  end

  @doc "GETs `url`'s body as it is (SAML metadata, say): `{:ok, binary}` or `{:error, reason}`."
  def get(url, headers \\ []), do: request(:get, url, headers, "")

  @doc "POSTs `form` (a map) form-encoded to `url` and decodes the JSON object answered."
  def post_form(url, form, headers \\ []) do
    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"} | headers
    ]

    with {:ok, body} <- request(:post, url, headers, URI.encode_query(form)), do: decode(body)
  end

  defp request(method, url, headers, body) do
    case :hackney.request(method, url, headers, body, @options) do
      {:ok, status, _headers, body} when status in 200..299 -> {:ok, body}
      {:ok, status, _headers, _body} -> {:error, {:status, status}}
      {:ok, status, _headers} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = json} -> {:ok, json}
      _other -> {:error, :invalid_json}
    end
  end
end
