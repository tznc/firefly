defmodule FireflyWeb.StaffLive.Screening do
  @moduledoc """
  The screening lists (staff only; see `Firefly.Moderation.Screening`):
  screened emails (addresses or `*@domain` patterns), IPs (addresses or
  ranges) and URLs (domains), one tab each, with how often each blocked a
  sign-up or post and when it last did. Staff add and remove entries;
  both, and every block, are in the staff log.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Moderation.{ScreenedItem, Screening}

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_screening) do
      {:ok, assign(socket, :page_title, gettext("Screening"))}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = if params["kind"] in ScreenedItem.kinds(), do: params["kind"], else: "email"
    {:noreply, socket |> assign(:kind, kind) |> load()}
  end

  defp load(socket) do
    kind = socket.assigns.kind

    socket
    |> assign(:items, Screening.list(kind))
    |> assign(:counts, Screening.counts())
    |> assign(:form, to_form(Screening.change(%{kind: kind})))
  end

  @impl true
  def handle_event(event, params, socket) do
    if can?(socket.assigns.current_user, :manage_screening),
      do: screening_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}
  end

  defp screening_event("add", %{"screened_item" => params}, socket) do
    params = Map.put(params, "kind", socket.assigns.kind)

    case Screening.create(params, socket.assigns.current_user) do
      {:ok, item} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Screened %{value}.", value: item.value)) |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp screening_event("delete", %{"id" => id}, socket) do
    case Screening.delete(id, socket.assigns.current_user) do
      {:ok, item} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Removed %{value}.", value: item.value)) |> load()}

      {:error, :not_found} ->
        {:noreply, load(socket)}
    end
  end

  defp kind_label("email"), do: gettext("Emails")
  defp kind_label("ip"), do: gettext("IP addresses")
  defp kind_label("url"), do: gettext("URLs")

  defp help("email"),
    do:
      gettext(
        "Addresses that can't sign up. Use * for any run of characters, as in *@spam.example for a whole domain."
      )

  defp help("ip"),
    do: gettext("Addresses or ranges (like 203.0.113.0/24) that can't sign up or post.")

  defp help("url"),
    do: gettext("Domains that can't be linked in posts and messages (their subdomains too).")

  defp placeholder("email"), do: "*@spam.example"
  defp placeholder("ip"), do: "203.0.113.0/24"
  defp placeholder("url"), do: "spam.example"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title={gettext("Screening")} navigate={~p"/staff/screening"}>
        <:subtitle>{gettext("Block spam at the door: sign-ups and posts that match are refused and logged.")}</:subtitle>
      </.page_header>

      <div role="tablist" class="tabs tabs-border">
        <.link
          :for={kind <- ScreenedItem.kinds()}
          patch={~p"/staff/screening?#{%{kind: kind}}"}
          role="tab"
          id={"tab-" <> kind}
          class={["tab", @kind == kind && "tab-active"]}
          aria-selected={to_string(@kind == kind)}
        >
          {kind_label(kind)} <span class="badge badge-sm ml-1">{@counts[kind]}</span>
        </.link>
      </div>

      <p class="text-sm text-base-content/70">{help(@kind)}</p>

      <.form for={@form} id="screen-form" phx-submit="add" class="flex flex-wrap items-end gap-2">
        <.input field={@form[:value]} type="text" label={gettext("Add")} placeholder={placeholder(@kind)} />
        <.button variant="primary" class="mb-2">{gettext("Screen it")}</.button>
      </.form>

      <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table id="screened" class="table">
          <thead>
            <tr>
              <th>{gettext("Value")}</th>
              <th>{gettext("Blocked")}</th>
              <th>{gettext("Last blocked")}</th>
              <th>{gettext("Added by")}</th>
              <th><span class="sr-only">{gettext("Actions")}</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@items == []}>
              <td colspan="5" class="text-base-content/70">{gettext("Nothing screened yet.")}</td>
            </tr>
            <tr :for={item <- @items} id={"screened-#{item.id}"}>
              <td class="font-mono">{item.value}</td>
              <td>{item.match_count}</td>
              <td>
                <.time_ago :if={item.last_matched_at} id={"matched-#{item.id}"} at={item.last_matched_at} />
                <span :if={!item.last_matched_at} class="text-base-content/60">{gettext("never")}</span>
              </td>
              <td>{item.created_by && "@" <> item.created_by.username}</td>
              <td>
                <button
                  phx-click="delete"
                  phx-value-id={item.id}
                  data-confirm={gettext("Stop screening %{value}?", value: item.value)}
                  class="btn btn-ghost btn-xs"
                >
                  {gettext("Remove")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
