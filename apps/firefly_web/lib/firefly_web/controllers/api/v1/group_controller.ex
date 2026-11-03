defmodule FireflyWeb.Api.V1.GroupController do
  @moduledoc """
  Groups the user may see, their members, and joining (or asking to join)
  and leaving one.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Groups
  alias FireflyWeb.Api.Pagination
  alias FireflyWeb.Api.V1.UserJSON

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "read" when action in [:index, :show, :members])
  plug(:require_scope, "users:write" when action in [:join, :leave])

  def index(conn, params) do
    groups = Groups.list_visible(current_user(conn))

    Pagination.render(conn, groups, params, fn {group, count} ->
      group |> data() |> Map.put(:members_count, count)
    end)
  end

  def show(conn, %{"name" => name}) do
    with {:ok, group} <- fetch(name, current_user(conn)) do
      ok(conn, data(group))
    end
  end

  def members(conn, %{"name" => name} = params) do
    with {:ok, group} <- fetch(name, current_user(conn)) do
      Pagination.render(conn, Groups.members(group), params, fn {user, owner?} ->
        Map.put(UserJSON.data(user), :owner, owner?)
      end)
    end
  end

  @doc "Joins an open group, or asks to join one that takes requests (`message`)."
  def join(conn, %{"name" => name} = params) do
    user = current_user(conn)

    with {:ok, group} <- fetch(name, user) do
      case Groups.join(group, user, params["message"]) do
        {:ok, status} -> ok(conn, %{status: status})
        {:error, reason} -> {:error, {422, Groups.message(reason)}}
      end
    end
  end

  def leave(conn, %{"name" => name}) do
    user = current_user(conn)

    with {:ok, group} <- fetch(name, user) do
      case Groups.remove_member(group, user, user) do
        {:ok, _} -> no_content(conn)
        {:error, reason} -> {:error, {422, Groups.message(reason)}}
      end
    end
  end

  defp fetch(name, user) do
    case Groups.get_by_name(name) do
      %{} = group -> if Groups.visible?(group, user), do: {:ok, group}, else: {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  defp data(group) do
    Map.take(group, [
      :id,
      :name,
      :description,
      :visibility,
      :membership,
      :mentionable,
      :messageable
    ])
  end
end
