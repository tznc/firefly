defmodule FireflyWeb.StaffLive.Dashboard do
  @moduledoc """
  The admin dashboard (admins only; see `Firefly.Reports`): the period's
  numbers compared with the period before, a few charts, links to every
  report, and the running version against the latest release (see
  `Firefly.Upgrades`). The period is in the URL (`?period=30`, or `?from=&to=`).
  Results are cached for the day; "Refresh" computes them again.
  """
  use FireflyWeb, :live_view

  import FireflyWeb.ReportComponents

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Reports, Upgrades}

  @charts ~w(page_views signups posts)

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :view_reports) do
      {:ok, assign(socket, :page_title, "Dashboard")}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params, [])}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load(socket, socket.assigns.params, refresh: true)}
  end

  defp load(socket, params, opts) do
    range = Reports.range(params)
    overview = Reports.overview(range, opts)

    charts =
      for id <- @charts, report = Reports.get(id) do
        {report, Reports.run(report, range, opts).result}
      end

    socket
    |> assign(:params, params)
    |> assign(:version, Upgrades.status())
    |> assign(:repo, Upgrades.repo())
    |> assign(:range, range)
    |> assign(:metrics, overview.result)
    |> assign(:computed_at, overview.computed_at)
    |> assign(:charts, charts)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Dashboard" navigate={~p"/staff/dashboard"}>
        <:subtitle>
          How the forum is doing, {@range.from} to {@range.to}, compared with the period before.
        </:subtitle>
        <:actions>
          <.link navigate={~p"/staff/reports"} class="btn btn-sm">All reports</.link>
        </:actions>
      </.page_header>

      <.period_picker path={~p"/staff/dashboard"} range={@range} params={@params} />

      <FireflyWeb.UpgradeComponents.version_status status={@version} repo={@repo} />

      <section id="overview" class="grid grid-cols-2 gap-3 md:grid-cols-4">
        <.stat :for={metric <- @metrics} metric={metric} />
      </section>

      <section :for={{report, result} <- @charts} class="space-y-2">
        <h2 class="flex items-center justify-between text-lg font-semibold">
          {report.title()}
          <.link
            navigate={~p"/staff/reports/#{report.id()}?#{range_query(@range)}"}
            class="link text-sm font-normal"
          >
            Details
          </.link>
        </h2>
        <.report_result id={"chart-#{report.id()}"} result={result} table={false} />
      </section>

      <p class="text-xs text-base-content/70">
        Computed {@computed_at}.
        <button id="refresh" phx-click="refresh" class="link">Refresh</button>
      </p>
    </Layouts.app>
    """
  end

  @doc false
  def range_query(range), do: URI.encode_query(from: range.from, to: range.to)
end
