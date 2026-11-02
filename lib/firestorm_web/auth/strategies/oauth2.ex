defmodule FirestormWeb.Auth.Strategies.OAuth2 do
  @moduledoc """
  What the in-house Ueberauth strategies (`X`, `Slack`) share: an OAuth 2
  authorization-code flow against a provider's endpoints, with optional
  PKCE (the verifier is kept in a signed cookie between the two phases),
  then fetching the user as JSON.

  Each strategy's credentials are its own config:
  `config :ueberauth, <strategy module>, client_id: ..., client_secret: ...`.
  """

  import Plug.Conn
  import Ueberauth.Strategy.Helpers

  @pkce_cookie "firefly_oauth_pkce"

  @doc """
  An OAuth2 client for `module`'s endpoints (`endpoints`: `:site`,
  `:authorize_url`, `:token_url`), redirecting to `redirect_uri`.
  """
  def client(module, endpoints, redirect_uri) do
    config = Application.get_env(:ueberauth, module, [])

    [
      strategy: OAuth2.Strategy.AuthCode,
      client_id: config[:client_id],
      client_secret: config[:client_secret],
      redirect_uri: redirect_uri
    ]
    |> Keyword.merge(endpoints)
    |> OAuth2.Client.new()
    |> OAuth2.Client.put_serializer("application/json", Jason)
  end

  @doc "The scopes to ask for: the provider's configured `default_scope`, else `default`."
  def scope(conn, default), do: Keyword.get(options(conn) || [], :default_scope, default)

  @doc "The request phase: redirects to the provider's authorization page."
  def request(conn, client, scope, opts \\ []) do
    params = with_state_param([scope: scope], conn)

    if opts[:pkce] do
      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
      params = params ++ [code_challenge: challenge, code_challenge_method: "S256"]

      conn
      |> put_resp_cookie(@pkce_cookie, verifier, sign: true, max_age: 600, same_site: "Lax")
      |> redirect!(OAuth2.Client.authorize_url!(client, params))
    else
      redirect!(conn, OAuth2.Client.authorize_url!(client, params))
    end
  end

  @doc """
  The callback phase: trades the code for a token and fetches `user_url`.
  Returns `{:ok, conn, user}` (a decoded JSON map) or `{:error, conn}` with
  Ueberauth's errors set.
  """
  def callback(conn, client, user_url, opts \\ [])

  def callback(%Plug.Conn{params: %{"code" => code}} = conn, client, user_url, opts) do
    {conn, params} = token_params(conn, code, opts)

    with {:ok, client} <- OAuth2.Client.get_token(client, params),
         {:ok, %OAuth2.Response{status_code: 200, body: user}} when is_map(user) <-
           OAuth2.Client.get(client, user_url) do
      {:ok, conn, user}
    else
      {:error, %OAuth2.Error{reason: reason}} -> {:error, fail(conn, inspect(reason))}
      {:error, %OAuth2.Response{body: body}} -> {:error, fail(conn, inspect(body))}
      other -> {:error, fail(conn, inspect(other))}
    end
  end

  def callback(%Plug.Conn{params: %{"error" => error}} = conn, _client, _user_url, _opts),
    do: {:error, set_errors!(conn, [error("auth_failed", error)])}

  def callback(conn, _client, _user_url, _opts),
    do: {:error, set_errors!(conn, [error("missing_code", "No code received")])}

  defp token_params(conn, code, opts) do
    if opts[:pkce] do
      conn = fetch_cookies(conn, signed: [@pkce_cookie])
      verifier = conn.cookies[@pkce_cookie]
      {delete_resp_cookie(conn, @pkce_cookie), [code: code, code_verifier: verifier]}
    else
      {conn, [code: code]}
    end
  end

  defp fail(conn, details), do: set_errors!(conn, [error("auth_failed", details)])
end
