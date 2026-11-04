defmodule FireflyWeb.StaffLive.Webhooks do
  @moduledoc """
  Outbound webhooks (admins only; see `Firefly.Webhooks`): the list, with
  each one's state and last delivery, and a form to add one. Each links to
  its page (`FireflyWeb.StaffLive.Webhook`) to edit it and see its
  deliveries.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Webhooks

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_webhooks) do
      {:ok,
       socket
       |> assign(:page_title, "Webhooks")
       |> assign(:webhooks, Webhooks.list())
       |> assign(:form, to_form(Webhooks.change()))}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save", %{"webhook" => params}, socket) do
    case Webhooks.create(params, socket.assigns.current_user) do
      {:ok, webhook} ->
        {:noreply,
         socket
         |> put_flash(:info, "Webhook added.")
         |> push_navigate(to: ~p"/staff/webhooks/#{webhook.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title="Webhooks" navigate={~p"/staff/webhooks"}>
        <:subtitle>Send events to other services as they happen.</:subtitle>
      </.page_header>

      <p :if={@webhooks == []} id="webhooks-empty" class="text-base-content/70">No webhooks yet.</p>

      <ul :if={@webhooks != []} id="webhooks" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
        <li :for={webhook <- @webhooks} id={"webhook-#{webhook.id}"} class="flex flex-wrap items-center gap-2 p-3">
          <span class={["badge badge-sm", if(webhook.active, do: "badge-success", else: "badge-ghost")]}>
            {if webhook.active, do: "Active", else: "Off"}
          </span>
          <.link navigate={~p"/staff/webhooks/#{webhook.id}"} class="link flex-1 break-all font-medium">
            {webhook.payload_url}
          </.link>
          <span class="text-sm text-base-content/70">
            {if webhook.wildcard, do: "All events", else: Enum.join(webhook.event_types, ", ")}
          </span>
          <span :if={webhook.last_status} class="text-sm text-base-content/70">
            · last {webhook.last_status}
          </span>
        </li>
      </ul>

      <FireflyWeb.StaffLive.Webhook.webhook_form form={@form} title="Add a webhook" submit="Add webhook" />
    </Layouts.app>
    """
  end
end
