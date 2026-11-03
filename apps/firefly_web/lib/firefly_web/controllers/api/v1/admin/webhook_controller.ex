defmodule FireflyWeb.Api.V1.Admin.WebhookController do
  @moduledoc "Outbound webhooks (admins; `admin` scope; see `Firefly.Webhooks`)."
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Webhooks
  alias FireflyWeb.Api.Pagination

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "admin")

  @fields ~w(payload_url secret wildcard event_types category_ids tag_names group_ids active)

  def index(conn, params) do
    with :ok <- allowed(conn), do: Pagination.render(conn, Webhooks.list(), params, &data/1)
  end

  def show(conn, %{"id" => id}) do
    with :ok <- allowed(conn), {:ok, webhook} <- fetch(id), do: ok(conn, data(webhook))
  end

  def create(conn, params) do
    with :ok <- allowed(conn),
         {:ok, webhook} <- Webhooks.create(Map.take(params, @fields), current_user(conn)) do
      ok(conn, data(webhook), 201)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- allowed(conn),
         {:ok, webhook} <- fetch(id),
         {:ok, webhook} <- Webhooks.update(webhook, Map.take(params, @fields), current_user(conn)) do
      ok(conn, data(webhook))
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- allowed(conn),
         {:ok, webhook} <- fetch(id),
         :ok <- Webhooks.delete(webhook, current_user(conn)) do
      no_content(conn)
    end
  end

  defp allowed(conn), do: permit(current_user(conn), :manage_webhooks)

  defp fetch(id) do
    case int(id) && Webhooks.get(int(id)) do
      nil -> {:error, :not_found}
      webhook -> {:ok, webhook}
    end
  end

  defp data(webhook) do
    Map.take(webhook, [
      :id,
      :payload_url,
      :content_type,
      :wildcard,
      :event_types,
      :category_ids,
      :tag_names,
      :group_ids,
      :active,
      :failure_count,
      :last_status,
      :last_delivery_at
    ])
  end
end
