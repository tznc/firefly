defmodule Firefly.Accounts.Auth.Strategies.OIDC do
  @moduledoc """
  Ueberauth strategy for the configured OpenID Connect provider (see
  `Firefly.Accounts.Auth.OIDC`). The request phase sends the browser to the
  provider with Ueberauth's `state`, a fresh `nonce` and a PKCE challenge;
  the nonce and PKCE verifier wait in a signed, short-lived cookie. The
  callback trades the code for tokens and accepts the login only with a
  valid ID token carrying that nonce.
  """
  use Ueberauth.Strategy

  import Plug.Conn

  alias Firefly.Accounts.Auth.OIDC
  alias Ueberauth.Auth.{Extra, Info}

  @cookie "firefly_oidc"

  @impl Ueberauth.Strategy
  def handle_request!(conn) do
    case OIDC.metadata() do
      {:ok, meta} ->
        verifier = random()
        nonce = random()
        challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
        state = Keyword.fetch!(with_state_param([], conn), :state)

        conn
        |> put_resp_cookie(@cookie, %{verifier: verifier, nonce: nonce},
          sign: true,
          max_age: 600,
          same_site: "Lax"
        )
        |> redirect!(OIDC.authorize_url(meta, callback_url(conn), state, nonce, challenge))

      {:error, reason} ->
        set_errors!(conn, [error("unavailable", inspect(reason))])
    end
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @impl Ueberauth.Strategy
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) when is_binary(code) do
    conn = fetch_cookies(conn, signed: [@cookie])
    login = conn.cookies[@cookie]
    conn = delete_resp_cookie(conn, @cookie)

    with %{verifier: verifier, nonce: nonce} <- login || {:error, :no_login_in_progress},
         {:ok, meta} <- OIDC.metadata(),
         {:ok, tokens} <- OIDC.exchange_code(meta, code, verifier, callback_url(conn)),
         {:ok, claims} <- OIDC.verify_id_token(meta, tokens["id_token"], nonce) do
      put_private(conn, :oidc_claims, OIDC.userinfo(meta, tokens["access_token"], claims))
    else
      {:error, reason} -> set_errors!(conn, [error("invalid_login", inspect(reason))])
    end
  end

  def handle_callback!(%Plug.Conn{params: %{"error" => error}} = conn),
    do: set_errors!(conn, [error("auth_failed", to_string(error))])

  def handle_callback!(conn),
    do: set_errors!(conn, [error("missing_code", "No code received")])

  @impl Ueberauth.Strategy
  def handle_cleanup!(conn), do: put_private(conn, :oidc_claims, nil)

  @impl Ueberauth.Strategy
  def uid(conn), do: conn.private.oidc_claims["sub"]

  @impl Ueberauth.Strategy
  def info(conn) do
    claims = conn.private.oidc_claims

    %Info{
      name: claims["name"],
      first_name: claims["given_name"],
      last_name: claims["family_name"],
      nickname: claims["preferred_username"] || claims["nickname"],
      email: claims["email"],
      image: claims["picture"]
    }
  end

  @impl Ueberauth.Strategy
  def extra(conn), do: %Extra{raw_info: %{user: conn.private.oidc_claims}}
end
