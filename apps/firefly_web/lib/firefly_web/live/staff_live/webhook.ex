defmodule FireflyWeb.StaffLive.Webhook do
  @moduledoc """
  One webhook (admins only; see `Firefly.Webhooks`): edit or delete it,
  send it a ping, and read its delivery log, each delivery's request and
  response, with a button to send it again.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Discussion, Groups, Repo, Webhooks}
  alias Firefly.Webhooks.{Delivery, Webhook}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    with true <- can?(user, :manage_webhooks),
         %Webhook{} = webhook <- Webhooks.get(id) do
      {:ok,
       socket
       |> assign(:page_title, "Webhook")
       |> assign(:webhook, webhook)
       |> assign(:open, nil)
       |> assign(:form, to_form(Webhooks.change(webhook, %{})))
       |> load()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, denied_message(user))
         |> push_navigate(to: ~p"/staff/webhooks")}
    end
  end

  defp load(socket), do: assign(socket, :deliveries, Webhooks.deliveries(socket.assigns.webhook))

  @impl true
  def handle_event("save", %{"webhook" => params}, socket) do
    params = Map.merge(%{"event_types" => [], "category_ids" => [], "group_ids" => []}, params)

    case Webhooks.update(socket.assigns.webhook, params, socket.assigns.current_user) do
      {:ok, webhook} ->
        {:noreply,
         socket
         |> put_flash(:info, "Webhook saved.")
         |> assign(:webhook, webhook)
         |> assign(:form, to_form(Webhooks.change(webhook, %{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :update))}
    end
  end

  def handle_event("delete", _params, socket) do
    :ok = Webhooks.delete(socket.assigns.webhook, socket.assigns.current_user)

    {:noreply,
     socket
     |> put_flash(:info, "Webhook deleted.")
     |> push_navigate(to: ~p"/staff/webhooks")}
  end

  def handle_event("ping", _params, socket) do
    :ok = Webhooks.ping(socket.assigns.webhook)
    {:noreply, socket |> put_flash(:info, "Ping queued.") |> load()}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("toggle", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, assign(socket, :open, if(socket.assigns.open == id, do: nil, else: id))}
  end

  def handle_event("redeliver", %{"id" => id}, socket) do
    case Repo.get_by(Delivery, id: id, webhook_id: socket.assigns.webhook.id) do
      nil ->
        {:noreply, socket}

      delivery ->
        :ok = Webhooks.redeliver(delivery)
        {:noreply, socket |> put_flash(:info, "Delivery queued again.") |> load()}
    end
  end

  @doc "The webhook form, for adding (`FireflyWeb.StaffLive.Webhooks`) and editing."
  attr :form, :any, required: true
  attr :title, :string, required: true
  attr :submit, :string, required: true

  def webhook_form(assigns) do
    assigns =
      assign(assigns,
        categories: Enum.map(Discussion.list_categories(), &{&1.title, &1.id}),
        groups: Enum.map(Groups.list_groups(), &{&1.name, &1.id}),
        tags: Enum.join(assigns.form[:tag_names].value || [], ", ")
      )

    ~H"""
    <.form for={@form} id="webhook-form" phx-submit="save" class="card border border-base-300 bg-base-100">
      <div class="card-body gap-2">
        <h2 class="card-title">{@title}</h2>
        <.input field={@form[:payload_url]} type="url" label="Payload URL" placeholder="https://example.com/hooks" />
        <.input
          field={@form[:secret]}
          type="text"
          label="Secret (signs each delivery; at least 12 characters)"
          autocomplete="off"
        />
        <.input field={@form[:wildcard]} type="checkbox" label="Send every event" />
        <fieldset class="fieldset">
          <legend class="fieldset-legend">Or these events</legend>
          <input type="hidden" name="webhook[event_types][]" value="" />
          <div class="flex flex-wrap gap-3">
            <label :for={type <- Webhook.types()} class="flex items-center gap-1 text-sm">
              <input
                type="checkbox"
                name="webhook[event_types][]"
                value={type}
                checked={type in (@form[:event_types].value || [])}
                class="checkbox checkbox-sm"
              />
              {String.capitalize(type)}
            </label>
          </div>
          <p :for={msg <- Enum.map(@form[:event_types].errors, &translate_error/1)} class="text-sm text-error">{msg}</p>
        </fieldset>
        <.input
          field={@form[:category_ids]}
          type="select"
          multiple
          label="Only in categories (optional)"
          options={@categories}
        />
        <.input
          id="webhook_tag_names"
          name="webhook[tag_names]"
          value={@tags}
          type="text"
          label="Only with tags (optional)"
        />
        <.input
          field={@form[:group_ids]}
          type="select"
          multiple
          label="Only by members of groups (optional)"
          options={@groups}
        />
        <.input field={@form[:active]} type="checkbox" label="Active" />
        <div class="flex justify-end">
          <.button variant="primary" phx-disable-with="Saving...">{@submit}</.button>
        </div>
      </div>
    </.form>
    """
  end

  defp status_class("delivered"), do: "badge-success"
  defp status_class("failed"), do: "badge-error"
  defp status_class("pending"), do: "badge-warning"
  defp status_class(_skipped), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title="Webhook" navigate={~p"/staff/webhooks"}>
        <:subtitle><span class="break-all">{@webhook.payload_url}</span></:subtitle>
        <:actions>
          <button phx-click="ping" class="btn btn-sm">Ping</button>
          <button phx-click="delete" data-confirm="Delete this webhook and its log?" class="btn btn-sm btn-error">
            Delete
          </button>
        </:actions>
      </.page_header>

      <p :if={!@webhook.active} id="webhook-off" class="alert alert-warning">
        This webhook is off<span :if={@webhook.failure_count > 0}> after {@webhook.failure_count} failed attempts in a row</span>. Turn it on below to send again.
      </p>

      <.webhook_form form={@form} title="Settings" submit="Save" />

      <section id="deliveries" class="space-y-2">
        <div class="flex items-center justify-between">
          <h2 class="text-lg font-semibold">Recent deliveries</h2>
          <button phx-click="refresh" class="btn btn-ghost btn-xs">Refresh</button>
        </div>
        <p :if={@deliveries == []} id="deliveries-empty" class="text-base-content/70">Nothing sent yet.</p>
        <div
          :for={delivery <- @deliveries}
          id={"delivery-#{delivery.id}"}
          class="rounded-box border border-base-300 bg-base-100 p-3 text-sm"
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class={["badge badge-sm", status_class(delivery.status)]}>{delivery.status}</span>
            <code>{delivery.event}</code>
            <span :if={delivery.response_status} class="text-base-content/70">HTTP {delivery.response_status}</span>
            <span :if={delivery.duration_ms} class="text-base-content/70">{delivery.duration_ms} ms</span>
            <span class="text-base-content/70">
              {delivery.attempts} {if delivery.attempts == 1, do: "attempt", else: "attempts"}
            </span>
            <.time_ago id={"delivery-#{delivery.id}-at"} at={delivery.inserted_at} class="text-base-content/70" />
            <span class="flex-1"></span>
            <button phx-click="toggle" phx-value-id={delivery.id} class="btn btn-ghost btn-xs">
              {if @open == delivery.id, do: "Hide", else: "Details"}
            </button>
            <button phx-click="redeliver" phx-value-id={delivery.id} class="btn btn-ghost btn-xs">
              Redeliver
            </button>
          </div>
          <p :if={delivery.error} class="mt-1 text-error">{delivery.error}</p>
          <div :if={@open == delivery.id} class="mt-2 grid gap-2 md:grid-cols-2">
            <div>
              <h3 class="font-medium">Request</h3>
              <pre class="overflow-x-auto rounded bg-base-200 p-2 text-xs">{headers_text(delivery.request_headers)}

    {delivery.request_body}</pre>
            </div>
            <div>
              <h3 class="font-medium">Response</h3>
              <pre class="overflow-x-auto rounded bg-base-200 p-2 text-xs">{headers_text(delivery.response_headers)}

    {delivery.response_body}</pre>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp headers_text(nil), do: ""
  defp headers_text(headers), do: Enum.map_join(headers, "\n", fn {k, v} -> "#{k}: #{v}" end)
end
