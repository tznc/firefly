defmodule Firefly.Accounts.Auth.Strategies.Slack do
  @moduledoc """
  Ueberauth strategy for "Sign in with Slack", Slack's OpenID Connect
  flow (`ueberauth_slack` uses the retired `identity.*` scopes). The uid
  is the workspace and user id together: Slack user ids are only unique
  within a workspace.

      config :ueberauth, Firefly.Accounts.Auth.Strategies.Slack,
        client_id: "...", client_secret: "..."
  """
  use Ueberauth.Strategy, default_scope: "openid profile email"

  alias Firefly.Accounts.Auth.Strategies.OAuth2
  alias Ueberauth.Auth.{Extra, Info}

  @endpoints [
    site: "https://slack.com",
    authorize_url: "/openid/connect/authorize",
    token_url: "/api/openid.connect.token"
  ]

  defp client(conn), do: OAuth2.client(__MODULE__, @endpoints, callback_url(conn))

  @impl Ueberauth.Strategy
  def handle_request!(conn),
    do: OAuth2.request(conn, client(conn), OAuth2.scope(conn, default_options()[:default_scope]))

  @impl Ueberauth.Strategy
  def handle_callback!(conn) do
    case OAuth2.callback(conn, client(conn), "/api/openid.connect.userInfo") do
      {:ok, conn, %{"ok" => true} = user} -> put_private(conn, :slack_user, user)
      {:ok, conn, user} -> set_errors!(conn, [error("auth_failed", inspect(user["error"]))])
      {:error, conn} -> conn
    end
  end

  @impl Ueberauth.Strategy
  def handle_cleanup!(conn), do: put_private(conn, :slack_user, nil)

  @impl Ueberauth.Strategy
  def uid(conn) do
    user = conn.private.slack_user
    "#{user["https://slack.com/team_id"]}/#{user["sub"]}"
  end

  @impl Ueberauth.Strategy
  def info(conn) do
    user = conn.private.slack_user

    %Info{
      name: user["name"],
      first_name: user["given_name"],
      last_name: user["family_name"],
      email: user["email"],
      image: user["picture"]
    }
  end

  @impl Ueberauth.Strategy
  def extra(conn), do: %Extra{raw_info: %{user: conn.private.slack_user}}
end
