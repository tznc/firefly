defmodule FirestormWeb.Web.CategoriesChannel do
  use FirestormWeb.Web, :channel
  alias FirestormWeb.Store.ReplenishResponse
  alias FirestormWeb.Web.Api.V1.FetchView

  intercept(["update"])

  def join("categories:" <> _id, _payload, socket) do
    {:ok, socket}
  end

  def handle_out("update", %ReplenishResponse{} = msg, socket) do
    push(socket, "update", FetchView.render("index.json", msg))
    {:noreply, socket}
  end
end
