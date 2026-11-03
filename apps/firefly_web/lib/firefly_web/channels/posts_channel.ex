defmodule FireflyWeb.PostsChannel do
  use FireflyWeb, :channel
  alias FireflyWeb.Api.V1.FetchJSON

  intercept(["update"])

  def join("posts:" <> _id, _payload, socket) do
    {:ok, socket}
  end

  def handle_out("update", msg, socket) do
    push(socket, "update", FetchJSON.index(msg))
    {:noreply, socket}
  end
end
