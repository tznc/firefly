defmodule Firefly.Accounts.Auth.Strategies.X do
  @moduledoc """
  Ueberauth strategy for logging in with X (Twitter) over OAuth 2.0 with
  PKCE (the maintained `ueberauth_twitter` only speaks OAuth 1.0a). X
  gives an id, username and name, but no email address.

      config :ueberauth, Firefly.Accounts.Auth.Strategies.X,
        client_id: "...", client_secret: "..."
  """
  use Ueberauth.Strategy, default_scope: "users.read tweet.read"

  alias Firefly.Accounts.Auth.Strategies.OAuth2
  alias Ueberauth.Auth.{Extra, Info}

  @endpoints [
    site: "https://api.x.com",
    authorize_url: "https://x.com/i/oauth2/authorize",
    token_url: "https://api.x.com/2/oauth2/token"
  ]

  defp client(conn), do: OAuth2.client(__MODULE__, @endpoints, callback_url(conn))

  @impl Ueberauth.Strategy
  def handle_request!(conn),
    do:
      OAuth2.request(conn, client(conn), OAuth2.scope(conn, default_options()[:default_scope]),
        pkce: true
      )

  @impl Ueberauth.Strategy
  def handle_callback!(conn) do
    case OAuth2.callback(conn, client(conn), "/2/users/me", pkce: true) do
      {:ok, conn, %{"data" => user}} -> put_private(conn, :x_user, user)
      {:ok, conn, _other} -> set_errors!(conn, [error("auth_failed", "No user returned")])
      {:error, conn} -> conn
    end
  end

  @impl Ueberauth.Strategy
  def handle_cleanup!(conn), do: put_private(conn, :x_user, nil)

  @impl Ueberauth.Strategy
  def uid(conn), do: conn.private.x_user["id"]

  @impl Ueberauth.Strategy
  def info(conn) do
    user = conn.private.x_user
    %Info{nickname: user["username"], name: user["name"]}
  end

  @impl Ueberauth.Strategy
  def extra(conn), do: %Extra{raw_info: %{user: conn.private.x_user}}
end
