defmodule FireflyWeb.Api.V1.CategoryController do
  @moduledoc """
  Categories the user may read, a category's threads, and (admins)
  creating, editing and deleting categories; members set their
  notification level for one.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Discussion
  alias Firefly.Notifications.Subscriptions
  alias FireflyWeb.Api.Pagination
  alias FireflyWeb.Api.V1.{CategoryJSON, ThreadJSON}

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "read" when action in [:index, :show, :threads])
  plug(:require_scope, "admin" when action in [:create, :update, :delete])
  plug(:require_scope, "users:write" when action == :notification_level)

  def index(conn, params) do
    categories = Discussion.list_categories(current_user(conn))
    Pagination.render(conn, categories, params, &CategoryJSON.data/1)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, category} <- fetch(id, current_user(conn)) do
      ok(conn, CategoryJSON.data(category))
    end
  end

  def threads(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, category} <- fetch(id, user) do
      Pagination.render(
        conn,
        Discussion.list_threads(category, user),
        params,
        &ThreadJSON.listed/1
      )
    end
  end

  def create(conn, params) do
    user = current_user(conn)

    with :ok <- permit(user, :manage_category),
         {:ok, category} <- Discussion.create_category(attrs(params), user) do
      ok(conn, CategoryJSON.data(category), 201)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with :ok <- permit(user, :manage_category),
         {:ok, category} <- fetch(id, user),
         {:ok, category} <- Discussion.update_category(category, attrs(params), user) do
      ok(conn, CategoryJSON.data(category))
    end
  end

  def delete(conn, %{"id" => id}) do
    user = current_user(conn)

    with :ok <- permit(user, :manage_category),
         {:ok, category} <- fetch(id, user),
         {:ok, _category} <- Discussion.delete_category(category, user) do
      no_content(conn)
    end
  end

  def notification_level(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, level} <- notification_level(params),
         {:ok, category} <- fetch(id, user),
         {:ok, _} <- Subscriptions.set_category_level(user, category, level) do
      ok(conn, %{level: level})
    end
  end

  defp attrs(params),
    do: Map.take(params, ~w(title description color position parent_id allow_accepted_answers))

  @doc false
  def fetch(id, user) do
    with id when is_integer(id) <- int(id),
         %{} = category <- Discussion.get_category(id),
         :ok <- permit(user, :view_category, category) do
      {:ok, category}
    else
      _missing_or_hidden -> {:error, :not_found}
    end
  end
end
