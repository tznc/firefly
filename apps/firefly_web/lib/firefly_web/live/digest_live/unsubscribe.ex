defmodule FireflyWeb.DigestLive.Unsubscribe do
  @moduledoc """
  Where a digest email's unsubscribe link leads: one button turns digests
  off for the account the link was made for, logged in or not (see
  `Firefly.Notifications.Digests`). A GET alone changes nothing, so link scanners
  can't unsubscribe anyone.
  """
  use FireflyWeb, :live_view

  alias Firefly.Notifications.Digests

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Unsubscribe")
     |> assign(:token, token)
     |> assign(:valid?, match?({:ok, _}, Digests.verify(token)))
     |> assign(:done?, false)}
  end

  @impl true
  def handle_event("unsubscribe", _params, socket) do
    case Digests.unsubscribe(socket.assigns.token) do
      {:ok, _user} -> {:noreply, assign(socket, :done?, true)}
      {:error, _reason} -> {:noreply, assign(socket, :valid?, false)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Digest emails" />
      <p :if={!@valid?} id="unsubscribe-invalid">This unsubscribe link has expired.</p>
      <p :if={@done?} id="unsubscribed">
        You won't get digest emails any more. You can turn them back on in your
        <.link navigate={~p"/settings/notifications"} class="link">notification settings</.link>.
      </p>
      <div :if={@valid? and not @done?} class="space-y-4">
        <p>Stop getting digest emails, the summaries of what you missed?</p>
        <button phx-click="unsubscribe" class="btn btn-primary">Unsubscribe</button>
      </div>
    </Layouts.app>
    """
  end
end
