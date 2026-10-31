defmodule FirestormWeb.Web.UsersChannel do
  use FirestormWeb.Web, :channel
  alias FirestormWeb.Web.Api.V1.FetchJSON

  intercept(["update"])

  def join("users:" <> _id, _payload, socket) do
    {:ok, socket}
  end

  def handle_out("update", msg, socket) do
    push(socket, "update", FetchJSON.index(msg))
    {:noreply, socket}
  end
end
