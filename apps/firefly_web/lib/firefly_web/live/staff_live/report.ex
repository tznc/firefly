defmodule FireflyWeb.StaffLive.Report do
  @moduledoc """
  One report (admins only; see `Firefly.Reports`) for a period: its chart
  or table, totals, and a CSV export (`FireflyWeb.ReportController`).
  """
  use FireflyWeb, :live_view

  import FireflyWeb.ReportComponents

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Reports
  alias FireflyWeb.StaffLive.Dashboard

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    report = Reports.get(id)

    cond do
      not can?(socket.assigns.current_user, :view_reports) ->
        {:ok,
         socket
         |> put_flash(:error, denied_message(socket.assigns.current_user))
         |> push_navigate(to: ~p"/")}

      is_nil(report) ->
        {:ok,
         socket |> put_flash(:error, "No such report.") |> push_navigate(to: ~p"/staff/reports")}

      true ->
        {:ok, socket |> assign(:report, report) |> assign(:page_title, report.title())}
    end
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, load(socket, params, [])}

  @impl true
  def handle_event("refresh", _params, socket),
    do: {:noreply, load(socket, socket.assigns.params, refresh: true)}

  defp load(socket, params, opts) do
    range = Reports.range(params)
    %{result: result, computed_at: at} = Reports.run(socket.assigns.report, range, opts)

    socket
    |> assign(:params, params)
    |> assign(:range, range)
    |> assign(:result, result)
    |> assign(:computed_at, at)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title={@report.title()} navigate={~p"/staff/reports/#{@report.id()}"}>
        <:subtitle>{@report.description()}</:subtitle>
        <:actions>
          <a
            id="export"
            href={~p"/staff/reports/#{@report.id()}/export?#{Dashboard.range_query(@range)}"}
            class="btn btn-sm"
            download
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> CSV
          </a>
          <.link navigate={~p"/staff/reports"} class="btn btn-sm btn-ghost">All reports</.link>
        </:actions>
      </.page_header>

      <.period_picker path={~p"/staff/reports/#{@report.id()}"} range={@range} params={@params} />

      <ul :if={elem(@result, 0) == :series} id="totals" class="flex flex-wrap gap-4 text-sm">
        <li :for={{label, total} <- Reports.totals(@result)}>
          {label}: <strong>{format(total, :count)}</strong>
        </li>
      </ul>

      <.report_result id="result" result={@result} />

      <p class="text-xs text-base-content/70">
        Computed {@computed_at}.
        <button id="refresh" phx-click="refresh" class="link">Refresh</button>
      </p>
    </Layouts.app>
    """
  end
end
