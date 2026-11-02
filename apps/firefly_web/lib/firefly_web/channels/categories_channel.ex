defmodule FireflyWeb.CategoriesChannel do
  use FireflyWeb, :channel
  alias Firefly.Discussion.Store.ReplenishResponse
  alias FireflyWeb.Api.V1.FetchJSON

  intercept(["update"])

  # The socket is anonymous: only categories a visitor may read can be joined,
  # and updates stop if the category is restricted later.
  def join("categories:" <> id, _payload, socket) do
    if public?(id), do: {:ok, socket}, else: {:error, %{reason: "not found"}}
  end

  def handle_out("update", %ReplenishResponse{} = msg, socket) do
    "categories:" <> id = socket.topic
    if public?(id), do: push(socket, "update", FetchJSON.index(msg))
    {:noreply, socket}
  end

  defp public?(id) do
    with {id, ""} <- Integer.parse(id),
         %{} = category <- Firefly.Repo.get(Firefly.Discussion.Category, id) do
      can?(nil, :view_category, category)
    else
      _ -> false
    end
  end
end
