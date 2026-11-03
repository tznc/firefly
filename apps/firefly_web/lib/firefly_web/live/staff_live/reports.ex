defmodule FireflyWeb.StaffLive.Reports do
  @moduledoc "Every report (admins only; see `Firefly.Reports`), each linking to its page."
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Reports

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :view_reports) do
      {:ok, socket |> assign(:page_title, "Reports") |> assign(:reports, Reports.list())}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title="Reports" navigate={~p"/staff/reports"}>
        <:subtitle>Activity, traffic and moderation over any period, as charts or CSV.</:subtitle>
        <:actions>
          <.link navigate={~p"/staff/dashboard"} class="btn btn-sm">Dashboard</.link>
        </:actions>
      </.page_header>

      <ul id="reports" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
        <li :for={report <- @reports} id={"report-#{report.id()}"} class="p-3">
          <.link navigate={~p"/staff/reports/#{report.id()}"} class="link font-medium">
            {report.title()}
          </.link>
          <p class="text-sm text-base-content/70">{report.description()}</p>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
