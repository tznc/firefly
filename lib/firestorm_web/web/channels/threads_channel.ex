defmodule FirestormWeb.Web.ThreadsChannel do
  use FirestormWeb.Web, :channel
  alias FirestormWeb.Store.ReplenishResponse
  alias FirestormWeb.Web.Api.V1.FetchJSON

  intercept(["update"])

  def join("threads:" <> _id, _payload, socket) do
    {:ok, socket}
  end

  def handle_out("update", %ReplenishResponse{} = msg, socket) do
    push(socket, "update", FetchJSON.index(msg))
    {:noreply, socket}
  end
end
