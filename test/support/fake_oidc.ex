defmodule FirestormWeb.FakeOIDC do
  @moduledoc """
  A fake OpenID Connect provider for tests, served by Bandit on a random
  local port: discovery, keys, a token endpoint that checks PKCE and signs
  ID tokens, and userinfo. Tests play the browser's part of the
  authorization step with `code/3`.
  """
  @behaviour Plug

  import Plug.Conn

  @client_id "oidc-client"

  def client_id, do: @client_id

  @doc "Starts the provider (under the test's supervisor) and returns its handle."
  def start do
    {:ok, agent} = Agent.start_link(fn -> nil end)
    {:ok, server} = Bandit.start_link(plug: {__MODULE__, agent}, port: 0, ip: :loopback)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    issuer = "http://localhost:#{port}"
    key = new_key("key-1")

    Agent.update(agent, fn _ ->
      %{issuer: issuer, keys: [key], signing_key: key, codes: %{}, algs: ["RS256", "ES256"]}
    end)

    %{
      agent: agent,
      server: server,
      issuer: issuer,
      discovery: issuer <> "/.well-known/openid-configuration"
    }
  end

  @doc "A new RSA signing key with key id `kid`."
  def new_key(kid) do
    {_, map} = JOSE.JWK.to_map(JOSE.JWK.generate_key({:rsa, 2048}))
    JOSE.JWK.from_map(Map.put(map, "kid", kid))
  end

  @doc "Publishes `keys` and signs new tokens with `signing_key`."
  def rotate(%{agent: agent}, keys, signing_key),
    do: Agent.update(agent, &%{&1 | keys: keys, signing_key: signing_key})

  @doc """
  The browser's visit to the authorization endpoint (`params`, from the
  redirect): returns a code for an ID token with `claims` merged into the
  defaults. `opts`: `:sign` (a function from claims to a token) to make
  it differently.
  """
  def code(%{agent: agent}, params, claims \\ %{}, opts \\ []) do
    code = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    entry = %{params: params, claims: claims, sign: opts[:sign]}
    Agent.update(agent, &put_in(&1, [:codes, code], entry))
    code
  end

  @doc "Signs `claims` with `jwk` (an RS256 key unless `alg` says otherwise)."
  def sign(jwk, claims, alg \\ "RS256") do
    {_, kid} = jwk |> JOSE.JWK.to_map() |> elem(1) |> Map.fetch("kid")
    {_, token} = jwk |> JOSE.JWT.sign(%{"alg" => alg, "kid" => kid}, claims) |> JOSE.JWS.compact()
    token
  end

  @impl true
  def init(agent), do: agent

  @impl true
  def call(%Plug.Conn{path_info: [".well-known", "openid-configuration"]} = conn, agent) do
    state = Agent.get(agent, & &1)

    json(conn, 200, %{
      issuer: state.issuer,
      authorization_endpoint: state.issuer <> "/authorize",
      token_endpoint: state.issuer <> "/token",
      jwks_uri: state.issuer <> "/jwks",
      userinfo_endpoint: state.issuer <> "/userinfo",
      id_token_signing_alg_values_supported: state.algs
    })
  end

  def call(%Plug.Conn{path_info: ["jwks"]} = conn, agent) do
    keys = Agent.get(agent, & &1.keys)
    json(conn, 200, %{keys: Enum.map(keys, &(&1 |> JOSE.JWK.to_public_map() |> elem(1)))})
  end

  def call(%Plug.Conn{path_info: ["token"], method: "POST"} = conn, agent) do
    {:ok, body, conn} = read_body(conn)
    form = URI.decode_query(body)
    state = Agent.get(agent, & &1)

    with %{params: params} = entry <- state.codes[form["code"]],
         true <- authenticated?(conn),
         true <- pkce?(params, form["code_verifier"]) do
      Agent.update(
        agent,
        &update_in(&1, [:codes], fn codes -> Map.delete(codes, form["code"]) end)
      )

      claims = Map.merge(default_claims(state, params), entry.claims)
      sign = entry.sign || fn claims -> sign(state.signing_key, claims) end
      json(conn, 200, %{id_token: sign.(claims), access_token: "access-" <> form["code"]})
    else
      _invalid -> json(conn, 400, %{error: "invalid_grant"})
    end
  end

  def call(%Plug.Conn{path_info: ["userinfo"]} = conn, _agent) do
    case get_req_header(conn, "authorization") do
      ["Bearer access-" <> _] -> json(conn, 200, %{sub: "user-1", locale: "en"})
      _ -> json(conn, 401, %{error: "invalid_token"})
    end
  end

  def call(conn, _agent), do: send_resp(conn, 404, "")

  defp authenticated?(conn),
    do:
      get_req_header(conn, "authorization") == [
        "Basic " <> Base.encode64("#{@client_id}:oidc-secret")
      ]

  defp pkce?(params, verifier) when is_binary(verifier),
    do:
      params["code_challenge"] ==
        Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp pkce?(_params, _verifier), do: false

  defp default_claims(state, params) do
    now = System.system_time(:second)

    %{
      "iss" => state.issuer,
      "aud" => @client_id,
      "sub" => "user-1",
      "iat" => now,
      "exp" => now + 300,
      "nonce" => params["nonce"],
      "email" => "ada@corp.example",
      "email_verified" => true,
      "name" => "Ada Lovelace",
      "preferred_username" => "ada"
    }
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
