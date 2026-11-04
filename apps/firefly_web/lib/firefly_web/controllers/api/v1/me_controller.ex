defmodule FireflyWeb.Api.V1.MeController do
  @moduledoc """
  The key's user: `GET /me` (with the key's scopes), `PATCH /me` (the
  public profile: as Settings > Profile, for members who aren't silenced;
  not the email address) and `PATCH /me/preferences`.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Accounts
  alias Firefly.Moderation.Posting
  alias FireflyWeb.Api.V1.UserJSON

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_user)
  plug(:require_scope, "read" when action == :show)
  plug(:require_scope, "users:write" when action in [:update, :preferences])

  def show(conn, _params) do
    key = conn.assigns.api_key

    ok(
      conn,
      conn
      |> current_user()
      |> UserJSON.me()
      |> Map.put(:api_key, %{
        name: key.name,
        scopes: key.scopes,
        expires_at: key.expires_at,
        global: Accounts.ApiKey.global?(key)
      })
    )
  end

  def update(conn, params) do
    with :ok <- Posting.check(current_user(conn), :like),
         {:ok, user} <-
           Accounts.update_user(
             current_user(conn),
             Map.take(params, ~w(username name bio website location))
           ) do
      ok(conn, UserJSON.me(user))
    end
  end

  def preferences(conn, params) do
    with {:ok, user} <-
           Accounts.update_preferences(
             current_user(conn),
             Map.take(params, UserJSON.preference_fields())
           ) do
      ok(conn, UserJSON.me(user))
    end
  end
end
