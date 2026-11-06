defmodule FireflyWeb.StaffLive.Security do
  @moduledoc """
  The security log (admins only, `:manage_security`): every member's
  logins and failed attempts, two-factor, passkey, password and API key
  changes, penalties and quarantined uploads, newest first, filtered by
  kind or by a username or address (see `Firefly.Security`).
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  import FireflyWeb.SecurityComponents

  alias Firefly.Security

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_security) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Security"))
       |> assign(:kind_options, Enum.map(Security.kinds(), &{event_label(&1), &1}))}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      "kind" => if(params["kind"] in Security.kinds(), do: params["kind"], else: ""),
      "q" => params["q"] || ""
    }

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:form, to_form(filters))
     |> assign(:events, Security.list(filters, params["page"]))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query = params |> Map.take(["kind", "q"]) |> Enum.reject(fn {_, v} -> v == "" end)
    {:noreply, push_patch(socket, to: ~p"/staff/security?#{Map.new(query)}")}
  end

  defp query_params(filters), do: for({k, v} <- filters, v != "", into: %{}, do: {k, v})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title={gettext("Security")} navigate={~p"/staff/security"}>
        <:subtitle>
          {gettext("Logins, failed attempts and account security changes, newest first.")}
        </:subtitle>
      </.page_header>

      <section id="security-log" class="space-y-4">
        <h2 class="text-lg font-semibold">{gettext("Security log")}</h2>
        <.form
          for={@form}
          id="security-log-filters"
          phx-change="filter"
          phx-submit="filter"
          class="flex flex-wrap items-end gap-4"
        >
          <.input
            field={@form[:kind]}
            type="select"
            label={gettext("Event")}
            prompt={gettext("Any event")}
            options={@kind_options}
          />
          <.input
            field={@form[:q]}
            type="search"
            label={gettext("Username or IP address")}
            phx-debounce="300"
          />
        </.form>

        <p :if={@events.entries == []} id="security-log-empty" class="text-base-content/70">
          {gettext("No security events.")}
        </p>

        <.events_table :if={@events.entries != []} id="security-events" events={@events.entries} show_user />

        <.pagination page={@events} path={~p"/staff/security"} params={query_params(@filters)} />
      </section>
    </Layouts.app>
    """
  end
end
