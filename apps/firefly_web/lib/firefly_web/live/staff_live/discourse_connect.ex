defmodule FireflyWeb.StaffLive.DiscourseConnect do
  @moduledoc """
  The sites that log people in through this one as their DiscourseConnect
  provider (admins only; see
  `Firefly.Accounts.Auth.DiscourseConnectProvider`): each with its secret
  and the hosts it may return to. Adding, changing and removing them goes
  to the staff log.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.SiteSettings
  alias Firefly.Accounts.Auth.DiscourseConnectProvider, as: Provider

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_sso_clients) do
      {:ok,
       socket
       |> assign(:page_title, "DiscourseConnect")
       |> assign(:enabled, SiteSettings.get("discourse_connect_provider_enabled"))
       |> assign(:endpoint, url(~p"/session/sso_provider"))
       |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket, editing \\ nil) do
    client =
      editing || %Firefly.Accounts.Auth.DiscourseConnectClient{secret: Provider.new_secret()}

    socket
    |> assign(:clients, Provider.list_clients())
    |> assign(:editing, editing)
    |> assign(:form, to_form(Provider.change_client(client)))
  end

  @impl true
  def handle_event("validate", %{"discourse_connect_client" => params}, socket) do
    client = socket.assigns.editing || %Firefly.Accounts.Auth.DiscourseConnectClient{}

    {:noreply,
     assign(socket, :form, to_form(Provider.change_client(client, params), action: :validate))}
  end

  def handle_event("save", %{"discourse_connect_client" => params}, socket) do
    admin = socket.assigns.current_user

    result =
      case socket.assigns.editing do
        nil -> Provider.create_client(params, admin)
        client -> Provider.update_client(client, params, admin)
      end

    case result do
      {:ok, client} ->
        {:noreply, socket |> put_flash(:info, "#{client.name} saved.") |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, load(socket, Provider.get_client!(id))}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, load(socket)}

  def handle_event("new_secret", _params, socket) do
    params = Map.put(socket.assigns.form.params, "secret", Provider.new_secret())
    client = socket.assigns.editing || %Firefly.Accounts.Auth.DiscourseConnectClient{}
    {:noreply, assign(socket, :form, to_form(Provider.change_client(client, params)))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    client = Provider.get_client!(id)
    {:ok, _} = Provider.delete_client(client, socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "#{client.name} removed.") |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="DiscourseConnect" navigate={~p"/staff/discourse-connect"}>
        <:subtitle>Other sites that log people in with their accounts here.</:subtitle>
      </.page_header>

      <div :if={!@enabled} id="provider-off" role="alert" class="alert alert-warning mb-4">
        <span>
          Off: turn on "Be a DiscourseConnect provider" in the
          <.link navigate={~p"/staff/settings"} class="link">settings</.link>
          for these sites to log in.
        </span>
      </div>

      <p class="mb-4 text-sm text-base-content/70">
        Each site's DiscourseConnect provider URL is <code id="provider-endpoint">{@endpoint}</code>,
        with the site's secret.
      </p>

      <p :if={@clients == []} id="clients-empty" class="text-base-content/70">No sites yet.</p>

      <ul :if={@clients != []} id="clients" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
        <li :for={client <- @clients} id={"client-#{client.id}"} class="flex flex-wrap items-center gap-2 p-3">
          <span class="flex-1 font-medium">{client.name}</span>
          <span class="text-sm text-base-content/70">{Enum.join(client.allowed_hosts, ", ")}</span>
          <button type="button" class="btn btn-ghost btn-xs" phx-click="edit" phx-value-id={client.id}>
            Edit
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs text-error"
            phx-click="delete"
            phx-value-id={client.id}
            data-confirm={"Remove #{client.name}? It won't be able to log anyone in."}
          >
            Remove
          </button>
        </li>
      </ul>

      <.form for={@form} id="client-form" phx-change="validate" phx-submit="save" class="mt-6 max-w-xl space-y-2">
        <h2 class="text-lg font-semibold">{if @editing, do: "Change #{@editing.name}", else: "Add a site"}</h2>
        <.input field={@form[:name]} label="Name" />
        <.input
          field={@form[:hosts]}
          type="textarea"
          label="Hosts it may return to"
          placeholder="forum.example.com"
        />
        <.input field={@form[:secret]} label="Secret" autocomplete="off" />
        <div class="flex gap-2">
          <.button variant="primary">{if @editing, do: "Save", else: "Add site"}</.button>
          <button type="button" class="btn" phx-click="new_secret">New secret</button>
          <button :if={@editing} type="button" class="btn btn-ghost" phx-click="cancel">Cancel</button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
