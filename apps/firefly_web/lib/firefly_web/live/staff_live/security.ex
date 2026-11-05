defmodule FireflyWeb.StaffLive.Security do
  @moduledoc """
  Security for admins (`:manage_security`):

    * the IP bans in force (see `Firefly.Security.Jail`), each with an
      unban button, a form to ban an address or range by hand (both
      staff-logged), and the addresses closest to a ban on this node;
    * the security log: every member's logins and failed attempts,
      two-factor, passkey, password and API key changes, penalties, bans and
      quarantined uploads, newest first, filtered by kind or by a username
      or address (see `Firefly.Security`).
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  import FireflyWeb.SecurityComponents

  alias Firefly.Security
  alias Firefly.Security.Jail

  @durations [{"1 hour", "60"}, {"1 day", "1440"}, {"1 week", "10080"}, {"30 days", "43200"}]

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_security) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Security"))
       |> assign(:kind_options, Enum.map(Security.kinds(), &{event_label(&1), &1}))
       |> assign(:ban_form, ban_form())
       |> assign_bans()}
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

  defp assign_bans(socket) do
    socket
    |> assign(:jail_on, Jail.enabled?())
    |> assign(:bans, Jail.active_bans())
    |> assign(:offenders, Jail.offenders())
  end

  defp ban_form(params \\ %{"ip" => "", "duration" => "1440", "reason" => ""}),
    do: to_form(params, as: :ban)

  defp durations,
    do:
      Enum.map(@durations, fn {label, minutes} -> {duration_label(label), minutes} end) ++
        [{gettext("Until unbanned"), "forever"}]

  defp duration_label("1 hour"), do: gettext("1 hour")
  defp duration_label("1 day"), do: gettext("1 day")
  defp duration_label("1 week"), do: gettext("1 week")
  defp duration_label("30 days"), do: gettext("30 days")

  @impl true
  def handle_event("ban", %{"ban" => params}, socket) do
    minutes =
      case Integer.parse(params["duration"] || "") do
        {minutes, ""} when minutes > 0 -> minutes
        _forever -> nil
      end

    case Jail.ban(params["ip"], socket.assigns.current_user,
           minutes: minutes,
           reason: params["reason"]
         ) do
      {:ok, ban} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Banned %{ip}.", ip: ban.ip))
         |> assign(:ban_form, ban_form())
         |> assign_bans()}

      {:error, message} ->
        {:noreply, socket |> put_flash(:error, message) |> assign(:ban_form, ban_form(params))}
    end
  end

  def handle_event("unban", %{"id" => id}, socket) do
    case Jail.get_ban(id) do
      nil ->
        {:noreply, assign_bans(socket)}

      ban ->
        {:ok, _ban} = Jail.unban(ban, socket.assigns.current_user)

        {:noreply,
         socket |> put_flash(:info, gettext("Unbanned %{ip}.", ip: ban.ip)) |> assign_bans()}
    end
  end

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

      <section id="bans" class="space-y-4">
        <h2 class="text-lg font-semibold">{gettext("Banned addresses")}</h2>
        <p :if={!@jail_on} id="jail-off" class="alert alert-warning">
          {gettext("Banning is off (Settings > Security > Banning): these bans aren't enforced.")}
        </p>

        <.form
          for={@ban_form}
          id="ban-form"
          phx-submit="ban"
          class="flex flex-wrap items-end gap-4"
        >
          <.input field={@ban_form[:ip]} label={gettext("IP address or range")} placeholder="203.0.113.7" required />
          <.input
            field={@ban_form[:duration]}
            type="select"
            label={gettext("For")}
            options={durations()}
          />
          <.input field={@ban_form[:reason]} label={gettext("Reason")} />
          <div class="mb-2">
            <.button variant="primary">{gettext("Ban")}</.button>
          </div>
        </.form>

        <p :if={@bans == []} id="bans-empty" class="text-base-content/70">
          {gettext("No address is banned.")}
        </p>

        <div :if={@bans != []} class="overflow-x-auto">
          <table id="active-bans" class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Address")}</th>
                <th>{gettext("Why")}</th>
                <th>{gettext("Bans")}</th>
                <th>{gettext("Until")}</th>
                <th><span class="sr-only">{gettext("Actions")}</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={ban <- @bans} id={"ban-#{ban.id}"}>
                <td class="font-mono text-xs">{ban.ip}</td>
                <td>
                  {ban.reason}
                  <span :if={ban.created_by} class="text-base-content/70">
                    ({ban.created_by.username})
                  </span>
                </td>
                <td>{ban.offences}</td>
                <td class="whitespace-nowrap">
                  <%= if ban.banned_until do %>
                    <.time_ago at={ban.banned_until} id={"ban-#{ban.id}-until"} />
                  <% else %>
                    {gettext("Until unbanned")}
                  <% end %>
                </td>
                <td>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    phx-click="unban"
                    phx-value-id={ban.id}
                    aria-label={gettext("Unban %{ip}", ip: ban.ip)}
                  >
                    {gettext("Unban")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <h3 class="font-semibold">{gettext("Recent offenders")}</h3>
        <p class="text-sm text-base-content/70">
          {gettext("Addresses with points towards a ban on this server now, closest first.")}
        </p>
        <p :if={@offenders == []} id="offenders-empty" class="text-sm">{gettext("None.")}</p>
        <div :if={@offenders != []} class="overflow-x-auto">
          <table id="offenders" class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Address")}</th>
                <th>{gettext("Jail")}</th>
                <th>{gettext("Points")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={offender <- @offenders}>
                <td class="font-mono text-xs">{offender.key}</td>
                <td>{offender.jail}</td>
                <td>{offender.points} / {offender.threshold}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

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
