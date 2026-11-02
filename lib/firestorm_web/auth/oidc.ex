defmodule FirestormWeb.Auth.OIDC do
  @moduledoc """
  A generic OpenID Connect provider (an organization's Okta, Keycloak,
  Azure AD, Authentik...), configured by the deployment:

      config :firestorm_web, FirestormWeb.Auth.OIDC,
        discovery_url: "https://idp.example.com/.well-known/openid-configuration",
        client_id: "...", client_secret: "...",
        scopes: "openid email profile",
        name: "Example SSO"

  (`FIREFLY_OIDC_*`, see `config/runtime.exs`). Logging in is the
  authorization code flow with PKCE, a `state` (Ueberauth's, checked
  against a cookie) and a `nonce` (see `FirestormWeb.Auth.Strategies.OIDC`).
  The ID token's signature is checked against the provider's published
  keys (JWKS), as are its issuer, audience, expiry and nonce. Accounts link
  by the token's `sub` (provider `"oidc"` in `user_identities`, see
  `FirestormWeb.Auth`); the email counts as confirmed only when the
  provider says `email_verified`.

  The discovery document and keys are cached for an hour. A token signed
  with a key we don't know (the provider rotated its keys) fetches the keys
  again, at most once a minute.
  """

  alias FirestormWeb.Auth.HTTP

  @ttl 3600
  @refresh_floor 60
  @skew 60
  @algs ~w(RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512 EdDSA)
  @default_scopes "openid email profile"

  defp config, do: Application.get_env(:firestorm_web, __MODULE__, [])

  @doc "Whether a discovery URL and client id are configured."
  def enabled?, do: present?(config()[:discovery_url]) and present?(config()[:client_id])

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc "The provider's name for people (`name`), by default \"Single sign-on\"."
  def label, do: if(present?(config()[:name]), do: config()[:name], else: "Single sign-on")

  @doc "The scopes asked for; always including `openid`."
  def scopes do
    scopes = if present?(config()[:scopes]), do: config()[:scopes], else: @default_scopes
    words = String.split(scopes)
    Enum.join(if("openid" in words, do: words, else: ["openid" | words]), " ")
  end

  @doc """
  The provider's discovery document (cached), which must name its issuer,
  authorization, token and key endpoints.
  """
  def metadata do
    cached({:metadata, config()[:discovery_url]}, false, fn ->
      with {:ok, meta} <- HTTP.get_json(config()[:discovery_url]), do: complete(meta)
    end)
  end

  defp complete(meta) do
    if Enum.all?(~w(issuer authorization_endpoint token_endpoint jwks_uri), &present?(meta[&1])),
      do: {:ok, meta},
      else: {:error, :incomplete_discovery}
  end

  @doc "The provider's authorization URL for the login's state, nonce and PKCE challenge."
  def authorize_url(meta, redirect_uri, state, nonce, challenge) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => config()[:client_id],
        "redirect_uri" => redirect_uri,
        "scope" => scopes(),
        "state" => state,
        "nonce" => nonce,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    endpoint = meta["authorization_endpoint"]
    endpoint <> if(String.contains?(endpoint, "?"), do: "&", else: "?") <> query
  end

  @doc """
  Trades the authorization `code` (and the PKCE `verifier`) for tokens.
  The client authenticates with HTTP Basic, the spec's default, unless the
  provider only accepts the secret in the form.
  """
  def exchange_code(meta, code, verifier, redirect_uri) do
    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "code_verifier" => verifier,
      "client_id" => config()[:client_id]
    }

    {form, headers} = client_auth(meta, form, config()[:client_secret])

    case HTTP.post_form(meta["token_endpoint"], form, headers) do
      {:ok, %{"id_token" => token} = tokens} when is_binary(token) -> {:ok, tokens}
      {:ok, _no_id_token} -> {:error, :no_id_token}
      {:error, reason} -> {:error, reason}
    end
  end

  # A public client (PKCE only) sends no secret.
  defp client_auth(meta, form, secret) do
    cond do
      not present?(secret) ->
        {form, []}

      meta["token_endpoint_auth_methods_supported"] == ["client_secret_post"] ->
        {Map.put(form, "client_secret", secret), []}

      true ->
        basic =
          Base.encode64(
            "#{URI.encode_www_form(form["client_id"])}:#{URI.encode_www_form(secret)}"
          )

        {form, [{"authorization", "Basic " <> basic}]}
    end
  end

  @doc """
  Verifies an ID token: signed (never `none` or a shared-secret algorithm)
  by one of the provider's keys, issued by the provider, for us
  (`aud`, and `azp` when there are several audiences), not expired, and
  carrying the `nonce` this login sent. Returns `{:ok, claims}` or
  `{:error, reason}`.
  """
  def verify_id_token(meta, token, nonce) when is_binary(token) and is_binary(nonce) do
    with {:ok, header} <- header(token),
         {:ok, alg} <- allowed_alg(meta, header["alg"]),
         {:ok, claims} <- verify_signature(meta, token, alg, header["kid"]) do
      check_claims(meta, claims, nonce)
    end
  end

  def verify_id_token(_meta, _token, _nonce), do: {:error, :invalid_token}

  defp header(token) do
    with [protected, _payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(protected, padding: false),
         {:ok, %{} = header} <- Jason.decode(json) do
      {:ok, header}
    else
      _malformed -> {:error, :invalid_token}
    end
  end

  defp allowed_alg(meta, alg) do
    advertised = meta["id_token_signing_alg_values_supported"] || ["RS256"]
    if alg in @algs and alg in advertised, do: {:ok, alg}, else: {:error, :unsupported_alg}
  end

  defp verify_signature(meta, token, alg, kid) do
    with {:ok, keys} <- keys(meta, false),
         :unknown_key <- verify_with(keys, token, alg, kid),
         # Perhaps the provider rotated its keys since we fetched them.
         {:ok, keys} <- keys(meta, true),
         :unknown_key <- verify_with(keys, token, alg, kid) do
      {:error, :unknown_key}
    end
  end

  defp verify_with(keys, token, alg, kid) do
    case Enum.filter(keys, &key_matches?(&1, alg, kid)) do
      [] -> :unknown_key
      candidates -> Enum.find_value(candidates, {:error, :bad_signature}, &verify(&1, token, alg))
    end
  end

  defp key_matches?(key, alg, kid) do
    key["use"] in [nil, "sig"] and key["alg"] in [nil, alg] and
      (is_nil(kid) or key["kid"] == kid) and key["kty"] == kty(alg)
  end

  defp kty("RS" <> _), do: "RSA"
  defp kty("PS" <> _), do: "RSA"
  defp kty("ES" <> _), do: "EC"
  defp kty("EdDSA"), do: "OKP"

  defp verify(key, token, alg) do
    case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), [alg], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _invalid -> nil
    end
  rescue
    _malformed -> nil
  end

  defp check_claims(meta, claims, nonce) do
    Enum.find_value(claim_checks(meta, claims, nonce), {:ok, claims}, fn {failed?, error} ->
      if failed?, do: {:error, error}
    end)
  end

  defp claim_checks(meta, claims, nonce) do
    now = System.system_time(:second)
    client_id = config()[:client_id]
    audiences = List.wrap(claims["aud"])

    [
      {claims["iss"] != meta["issuer"], :wrong_issuer},
      {client_id not in audiences, :wrong_audience},
      {length(audiences) > 1 and claims["azp"] != client_id, :wrong_audience},
      {not is_integer(claims["exp"]) or claims["exp"] + @skew < now, :expired},
      {is_integer(claims["iat"]) and claims["iat"] - @skew > now, :issued_in_future},
      {not (is_binary(claims["nonce"]) and Plug.Crypto.secure_compare(claims["nonce"], nonce)),
       :wrong_nonce},
      {not present?(claims["sub"]), :no_subject}
    ]
  end

  @doc """
  Adds what the provider's userinfo endpoint (if any) says about the user
  to the ID token's `claims`; only for the same subject, and never
  replacing the token's own claims. Without an endpoint, or if it fails,
  the claims stay as they are.
  """
  def userinfo(meta, access_token, claims) do
    with url when is_binary(url) <- meta["userinfo_endpoint"],
         true <- is_binary(access_token),
         {:ok, %{"sub" => sub} = info} <-
           HTTP.get_json(url, [{"authorization", "Bearer " <> access_token}]),
         true <- sub == claims["sub"] do
      Map.merge(info, claims)
    else
      _none -> claims
    end
  end

  # The signing keys, from the cache unless `refresh` (an unknown key id),
  # which refetches unless the keys are under a minute old.
  defp keys(meta, refresh) do
    key = {:jwks, meta["jwks_uri"]}

    fetch = fn ->
      case HTTP.get_json(meta["jwks_uri"]) do
        {:ok, %{"keys" => keys}} when is_list(keys) -> {:ok, Enum.filter(keys, &is_map/1)}
        {:ok, _other} -> {:error, :invalid_jwks}
        error -> error
      end
    end

    cached(key, refresh, fetch)
  end

  defp cached(key, refresh, fetch) do
    now = System.monotonic_time(:second)
    cache_key = {__MODULE__, key}

    case :persistent_term.get(cache_key, nil) do
      {fetched_at, value} when now - fetched_at < @refresh_floor ->
        {:ok, value}

      {fetched_at, value} when not refresh and now - fetched_at < @ttl ->
        {:ok, value}

      _stale ->
        with {:ok, value} <- fetch.() do
          :persistent_term.put(cache_key, {now, value})
          {:ok, value}
        end
    end
  end
end
