defmodule FirestormWeb.Web.PostsChannel do
  use FirestormWeb.Web, :channel
  alias FirestormWeb.Web.Api.V1.FetchView

  intercept(["update"])

  def join("posts:" <> _id, _payload, socket) do
    {:ok, socket}
  end

  def handle_out("update", msg, socket) do
    push(socket, "update", FetchView.render("index.json", msg))
    {:noreply, socket}
  end
end
