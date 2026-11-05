defmodule FireflyWeb.StaffLive.Emails do
  @moduledoc """
  The emails admin (admins only; see `Firefly.Notifications.EmailLog`):
  the log of every email sent, skipped or failed, filtered by status and
  template and searched by address or subject; sending a test email; and
  a preview of each template with sample data (see
  `Firefly.Notifications.Emails.previews/0`), its HTML in a sandboxed
  frame. The tab, filters and page are in the URL.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Notifications.{EmailLog, Emails}

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_emails) do
      previews = Emails.previews()

      {:ok,
       socket
       |> assign(:page_title, gettext("Emails"))
       |> assign(:previews, previews)
       |> assign(:templates, Enum.map(previews, &elem(&1, 0)))
       |> assign(:counts, EmailLog.last_day_counts())}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in ~w(log test previews), do: params["tab"], else: "log"

    filters = filters(params, socket.assigns.templates)

    preview =
      List.keyfind(socket.assigns.previews, params["preview"], 0) || hd(socket.assigns.previews)

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:filters, filters)
     |> assign(:preview, preview)
     |> assign(:page, if(tab == "log", do: EmailLog.list(filters, page_number(params))))}
  end

  defp filters(params, templates) do
    %{
      "status" => if(params["status"] in EmailLog.statuses(), do: params["status"], else: ""),
      "template" => if(params["template"] in templates, do: params["template"], else: ""),
      "q" => String.trim(params["q"] || "")
    }
  end

  defp page_number(params) do
    case Integer.parse(params["page"] || "") do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      params
      |> Map.take(~w(status template q))
      |> Map.put("tab", "log")
      |> Map.reject(fn {_key, value} -> value == "" end)

    {:noreply, push_patch(socket, to: ~p"/staff/emails?#{query}")}
  end

  def handle_event("preview", %{"preview" => template}, socket) do
    {:noreply, push_patch(socket, to: ~p"/staff/emails?#{%{tab: "previews", preview: template}}")}
  end

  def handle_event("send_test", %{"to" => to}, socket) do
    admin = socket.assigns.current_user

    if can?(admin, :manage_emails) do
      case EmailLog.send_test(to, admin) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             gettext("Test email sent to %{to} with %{adapter}.",
               to: String.trim(to),
               adapter: Firefly.Mailer.adapter_label()
             )
           )
           |> assign(:counts, EmailLog.last_day_counts())}

        {:error, :invalid_address} ->
          {:noreply, put_flash(socket, :error, gettext("That isn't an email address."))}

        {:error, error} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("%{adapter} couldn't send it: %{error}",
               adapter: Firefly.Mailer.adapter_label(),
               error: EmailLog.describe(error)
             )
           )
           |> assign(:counts, EmailLog.last_day_counts())}
      end
    else
      {:noreply, put_flash(socket, :error, denied_message(admin))}
    end
  end

  defp status_class("sent"), do: "badge-success"
  defp status_class("skipped"), do: "badge-ghost"
  defp status_class("failed"), do: "badge-error"

  defp status_label("sent"), do: gettext("sent")
  defp status_label("skipped"), do: gettext("skipped")
  defp status_label("failed"), do: gettext("failed")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title={gettext("Emails")} navigate={~p"/staff/emails"}>
        <:subtitle>
          {gettext("Today: %{sent} sent, %{skipped} skipped, %{failed} failed.",
            sent: @counts["sent"],
            skipped: @counts["skipped"],
            failed: @counts["failed"]
          )}
        </:subtitle>
      </.page_header>

      <div role="tablist" class="tabs tabs-border">
        <.link patch={~p"/staff/emails"} role="tab" class={["tab", @tab == "log" && "tab-active"]} aria-selected={to_string(@tab == "log")}>
          {gettext("Sent log")}
        </.link>
        <.link patch={~p"/staff/emails?tab=test"} role="tab" class={["tab", @tab == "test" && "tab-active"]} aria-selected={to_string(@tab == "test")}>
          {gettext("Test email")}
        </.link>
        <.link patch={~p"/staff/emails?tab=previews"} role="tab" class={["tab", @tab == "previews" && "tab-active"]} aria-selected={to_string(@tab == "previews")}>
          {gettext("Templates")}
        </.link>
      </div>

      <%= if @tab == "log" do %>
        <form id="email-filters" phx-change="filter" phx-submit="filter" class="grid gap-2 sm:grid-cols-3">
          <label class="input">
            <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
            <input type="search" name="q" value={@filters["q"]} phx-debounce="300" placeholder={gettext("Address or subject")} aria-label={gettext("Search emails")} />
          </label>
          <select name="status" class="select" aria-label={gettext("Status")}>
            <option value="">{gettext("Any status")}</option>
            <option :for={status <- EmailLog.statuses()} value={status} selected={@filters["status"] == status}>
              {status_label(status)}
            </option>
          </select>
          <select name="template" class="select" aria-label={gettext("Template")}>
            <option value="">{gettext("Any template")}</option>
            <option :for={template <- @templates} value={template} selected={@filters["template"] == template}>
              {template}
            </option>
          </select>
        </form>

        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table id="email-log" class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("When")}</th>
                <th>{gettext("To")}</th>
                <th>{gettext("Template")}</th>
                <th>{gettext("Subject")}</th>
                <th>{gettext("Status")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@page.entries == []}>
                <td colspan="5" class="text-base-content/70">{gettext("No emails yet.")}</td>
              </tr>
              <tr :for={email <- @page.entries} id={"email-#{email.id}"}>
                <td><.time_ago id={"email-at-#{email.id}"} at={email.inserted_at} /></td>
                <td>
                  <.link :if={email.user} navigate={~p"/staff/users/#{email.user.id}"} class="link">{email.to}</.link>
                  <span :if={!email.user}>{email.to}</span>
                </td>
                <td><code class="text-xs">{email.template}</code></td>
                <td>{email.subject}</td>
                <td>
                  <span class={["badge badge-sm", status_class(email.status)]}>{status_label(email.status)}</span>
                  <p :if={email.error} class="text-xs text-error">{email.error}</p>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <.pagination page={@page} path={~p"/staff/emails"} params={Map.reject(@filters, fn {_k, v} -> v == "" end)} />
      <% end %>

      <form :if={@tab == "test"} id="test-email" phx-submit="send_test" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-3">
          <p class="text-sm text-base-content/70">
            {gettext("Sends a short email through the configured mailer, to check delivery works. It shows in the log.")}
          </p>
          <p id="mail-adapter" class="text-sm">
            {gettext("Mailer: %{adapter}", adapter: Firefly.Mailer.adapter_label())}
          </p>
          <div class="flex flex-wrap items-end gap-2">
            <.input name="to" type="email" value={@current_user.email || ""} label={gettext("Send to")} />
            <.button variant="primary" phx-disable-with={gettext("Sending...")}>{gettext("Send test email")}</.button>
          </div>
        </div>
      </form>

      <section :if={@tab == "previews"} id="email-previews" class="space-y-3">
        <form id="preview-form" phx-change="preview">
          <.input
            name="preview"
            type="select"
            label={gettext("Template")}
            value={elem(@preview, 0)}
            options={@templates}
          />
        </form>
        <div class="card border border-base-300 bg-base-100">
          <div class="card-body gap-2">
            <dl class="grid grid-cols-[auto_1fr] gap-x-4 text-sm">
              <dt class="text-base-content/70">{gettext("To")}</dt>
              <dd id="preview-to">{EmailLog.recipients(elem(@preview, 1))}</dd>
              <dt class="text-base-content/70">{gettext("Subject")}</dt>
              <dd id="preview-subject">{elem(@preview, 1).subject}</dd>
            </dl>
            <iframe
              id="preview-html"
              title={gettext("Email preview")}
              sandbox=""
              srcdoc={elem(@preview, 1).html_body}
              class="h-96 w-full rounded-box border border-base-300 bg-white"
            >
            </iframe>
            <details>
              <summary class="cursor-pointer text-sm">{gettext("Plain text version")}</summary>
              <pre id="preview-text" class="mt-2 whitespace-pre-wrap text-sm">{elem(@preview, 1).text_body}</pre>
            </details>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
