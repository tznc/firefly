defmodule FireflyWeb.StaffLive.Imports do
  @moduledoc """
  Imports (admins only; see `Firefly.Import`): the runs of the importers,
  newest first, each with its counts per kind of record and its log. The
  importers run from the command line (`mix firefly.import`, or
  `bin/firefly eval` in a release), so this page follows them by reloading
  every few seconds while one is running.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Import
  alias Firefly.Import.Run

  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_imports) do
      {:ok, socket |> assign(:page_title, "Import") |> assign(:refreshing, false)}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, load(socket, params["run"])}

  @impl true
  def handle_info(:refresh, socket) do
    socket = assign(socket, :refreshing, false)
    {:noreply, load(socket, socket.assigns.selected && to_string(socket.assigns.selected.id))}
  end

  defp load(socket, run_id) do
    runs = Import.list_runs()
    selected = (run_id && Import.get_run(run_id)) || List.first(runs)
    socket = socket |> assign(:runs, runs) |> assign(:selected, selected)

    if connected?(socket) and Enum.any?(runs, &Run.running?/1) and not socket.assigns.refreshing do
      Process.send_after(self(), :refresh, @refresh_ms)
      assign(socket, :refreshing, true)
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Import" navigate={~p"/staff/import"}>
        <:subtitle>
          Content imported from other forums and platforms: Discourse, phpBB, vBulletin, NodeBB, Slack,
          Discord and GitHub Discussions.
        </:subtitle>
      </.page_header>

      <section id="import-help" class="space-y-2 text-sm">
        <p>
          Imports run from the command line, on the server. Run one again to resume it or pick up what's new;
          add <code>--dry-run</code> to see what it would do first.
        </p>
        <pre class="overflow-auto rounded-box bg-base-200 p-3 text-xs">mix firefly.import discourse --source-url postgres://user:password@host/discourse --uploads-dir uploads/default
    bin/firefly eval 'FireflyImport.CLI.main(~w(discourse --source-url postgres://user:password@host/discourse))'</pre>
      </section>

      <p :if={@runs == []} id="imports-empty" class="text-base-content/70">No imports yet.</p>

      <ul :if={@runs != []} id="import-runs" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
        <li :for={run <- @runs} id={"import-run-#{run.id}"} class="flex flex-wrap items-center gap-2 p-3">
          <.link patch={~p"/staff/import?run=#{run.id}"} class="link flex-1 font-medium">
            {run.source}{if run.dry_run, do: " (dry run)"}
          </.link>
          <span class={["badge badge-sm", status_class(run.status)]}>{run.status}</span>
          <span class="text-sm text-base-content/70">
            <.time_ago id={"import-run-#{run.id}-at"} at={run.inserted_at} />
          </span>
        </li>
      </ul>

      <section :if={@selected} id="import-run" class="space-y-3">
        <h2 class="font-semibold">
          {@selected.source}{if @selected.dry_run, do: " (dry run)"}: {@selected.status}
        </h2>
        <p :if={@selected.error} class="text-sm text-error">The import stopped with an error (see the log).</p>

        <table :if={@selected.counts != %{}} id="import-counts" class="table table-sm">
          <thead>
            <tr>
              <th>Records</th>
              <th class="text-right">Imported</th>
              <th class="text-right">Skipped</th>
              <th class="text-right">Failed</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{kind, counts} <- Enum.sort(@selected.counts)}>
              <td>{String.replace(kind, "_", " ")}</td>
              <td class="text-right">{Map.get(counts, "imported", 0)}</td>
              <td class="text-right">{Map.get(counts, "skipped", 0)}</td>
              <td class="text-right">{Map.get(counts, "failed", 0)}</td>
            </tr>
          </tbody>
        </table>

        <pre id="import-log" class="max-h-96 overflow-auto rounded-box bg-base-200 p-3 text-xs"><span :for={line <- @selected.log}>{line}<br /></span></pre>
      </section>
    </Layouts.app>
    """
  end

  defp status_class("running"), do: "badge-info"
  defp status_class("finished"), do: "badge-success"
  defp status_class(_failed), do: "badge-error"
end
