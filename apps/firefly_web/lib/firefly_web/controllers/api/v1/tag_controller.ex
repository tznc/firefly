defmodule FireflyWeb.Api.V1.TagController do
  @moduledoc "Tags in use, a tag's threads, and members' notification level for a tag."
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.{Discussion, Repo}
  alias Firefly.Discussion.Tag
  alias Firefly.Notifications.Subscriptions
  alias FireflyWeb.Api.Pagination
  alias FireflyWeb.Api.V1.ThreadJSON

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "read" when action in [:index, :threads])
  plug(:require_scope, "users:write" when action == :notification_level)

  def index(conn, params) do
    tags = Discussion.list_tags(current_user(conn))
    Pagination.render(conn, tags, params, &%{name: &1.name, threads_count: &1.threads_count})
  end

  def threads(conn, %{"name" => name} = params) do
    user = current_user(conn)

    with %Tag{} = tag <- get(name) do
      Pagination.render(conn, Discussion.tag_threads(tag, user), params, &ThreadJSON.listed/1)
    end
  end

  def notification_level(conn, %{"name" => name} = params) do
    user = current_user(conn)

    with {:ok, level} <- notification_level(params),
         %Tag{} = tag <- get(name),
         {:ok, _} <- Subscriptions.set_tag_level(user, tag, level) do
      ok(conn, %{level: level})
    end
  end

  defp get(name), do: Repo.get_by(Tag, name: String.downcase(name))
end
