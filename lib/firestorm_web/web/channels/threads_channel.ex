defmodule FirestormWeb.Web.ThreadsChannel do
  use FirestormWeb.Web, :channel
  alias FirestormWeb.Store.ReplenishResponse
  alias FirestormWeb.Web.Api.V1.FetchJSON

  intercept(["update"])

  # The socket is anonymous: only threads a visitor may read can be joined,
  # and updates stop if the thread is restricted later.
  def join("threads:" <> id, _payload, socket) do
    if public?(id), do: {:ok, socket}, else: {:error, %{reason: "not found"}}
  end

  def handle_out("update", %ReplenishResponse{} = msg, socket) do
    "threads:" <> id = socket.topic
    if public?(id), do: push(socket, "update", FetchJSON.index(msg))
    {:noreply, socket}
  end

  defp public?(id) do
    with {id, ""} <- Integer.parse(id),
         %{} = thread <- FirestormWeb.Repo.get(FirestormWeb.Forums.Thread, id) do
      can?(nil, :view_thread, thread)
    else
      _ -> false
    end
  end
end
