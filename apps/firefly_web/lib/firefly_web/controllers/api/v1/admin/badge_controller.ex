defmodule FireflyWeb.Api.V1.Admin.BadgeController do
  @moduledoc """
  Badges (admins; `admin` scope; see `Firefly.Badges`): creating, editing
  and deleting them, and granting and revoking them. Listing is public:
  `GET /badges`.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.{Accounts, Badges}
  alias Firefly.Badges.Badge
  alias FireflyWeb.Api.Pagination

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "read" when action == :index)
  plug(:require_scope, "admin" when action != :index)

  @fields ~w(name description icon badge_type grouping enabled allow_title multiple_grant listable)

  def index(conn, params) do
    badges = Enum.filter(Badges.list_badges(), &(&1.enabled and &1.listable))
    Pagination.render(conn, badges, params, &data/1)
  end

  def create(conn, params) do
    with :ok <- allowed(conn),
         {:ok, badge} <- Badges.create_badge(Map.take(params, @fields), current_user(conn)) do
      ok(conn, data(badge), 201)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- allowed(conn),
         {:ok, badge} <- fetch(id),
         {:ok, badge} <- Badges.update_badge(badge, Map.take(params, @fields), current_user(conn)) do
      ok(conn, data(badge))
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- allowed(conn),
         {:ok, badge} <- fetch(id),
         {:ok, _} <- message(Badges.delete_badge(badge, current_user(conn))) do
      no_content(conn)
    end
  end

  @doc "`POST /admin/badges/:id/grants` with `username` and an optional `reason`."
  def grant(conn, %{"id" => id} = params) do
    with :ok <- allowed(conn),
         {:ok, badge} <- fetch(id),
         %{} = user <- Accounts.get_user_by_username(params["username"] || ""),
         {:ok, user_badge} <-
           message(Badges.grant(badge, user, current_user(conn), params["reason"])) do
      ok(conn, %{id: user_badge.id, badge_id: badge.id, user_id: user.id}, 201)
    end
  end

  @doc "`DELETE /admin/badges/grants/:id` (a grant's id)."
  def revoke(conn, %{"grant_id" => id}) do
    with :ok <- allowed(conn),
         id when is_integer(id) <- int(id),
         {:ok, _} <- message(Badges.revoke(id, current_user(conn))) do
      no_content(conn)
    end
  end

  defp message({:error, reason}) when is_atom(reason) and reason != :not_found,
    do: {:error, {422, Badges.message(reason)}}

  defp message(result), do: result

  defp allowed(conn), do: permit(current_user(conn), :manage_badges)

  defp fetch(id) do
    case int(id) && Firefly.Repo.get(Badge, int(id)) do
      nil -> {:error, :not_found}
      badge -> {:ok, badge}
    end
  end

  defp data(badge) do
    Map.take(badge, [
      :id,
      :name,
      :description,
      :icon,
      :badge_type,
      :grouping,
      :enabled,
      :allow_title,
      :multiple_grant,
      :listable,
      :system,
      :grant_count
    ])
  end
end
