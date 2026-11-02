defmodule FirestormWeb.Web.StaffLive.Plugins do
  @moduledoc """
  Plugins (admins only; see `FirestormWeb.Plugins`): every installed plugin
  in load order, with its status, dependencies, dependents and problems.

  Uploading a bundle shows what it is and the permissions it requests
  before it's installed (or upgrades the installed plugin with its id).
  Enabling, disabling and uninstalling go through a confirm step that lists
  every plugin the change cascades to.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.Plugin.{Bundle, Host}
  alias FirestormWeb.Plugins

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_plugins) do
      {:ok,
       socket
       |> assign(:page_title, "Plugins")
       |> assign(preview: nil, confirm: nil)
       |> allow_upload(:bundle,
         accept: ~w(.zip),
         max_entries: 1,
         max_file_size: Bundle.max_size()
       )
       |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket), do: assign(socket, :plugins, Plugins.overview())

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("upload", _params, socket) do
    case consume_uploaded_entries(socket, :bundle, fn %{path: path}, _entry ->
           {:ok, Plugins.preview(File.read!(path))}
         end) do
      [{:ok, preview}] ->
        {:noreply,
         assign(socket, preview: preview, manifest: preview.bundle.manifest, confirm: nil)}

      [{:error, message}] ->
        {:noreply, put_flash(socket, :error, message)}

      [] ->
        {:noreply, put_flash(socket, :error, "Choose a plugin bundle (.zip) to upload.")}
    end
  end

  def handle_event("install", _params, %{assigns: %{preview: %{bundle: bundle}}} = socket) do
    case Plugins.install(bundle, socket.assigns.current_user) do
      {:ok, _row} ->
        verb = if socket.assigns.preview.current, do: "upgraded", else: "installed (disabled)"

        {:noreply,
         socket
         |> put_flash(:info, "#{bundle.manifest.name} #{bundle.manifest.version} #{verb}.")
         |> assign(:preview, nil)
         |> load()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("cancel_preview", _params, socket),
    do: {:noreply, assign(socket, :preview, nil)}

  def handle_event("confirm", %{"action" => action, "id" => id}, socket)
      when action in ~w(enable disable uninstall) do
    plan =
      case action do
        "enable" -> Plugins.enable_plan(id)
        "disable" -> Plugins.disable_plan(id)
        "uninstall" -> with :ok <- Plugins.uninstall_check(id), do: {:ok, [id]}
      end

    case plan do
      {:ok, ids} -> {:noreply, assign(socket, :confirm, %{action: action, id: id, ids: ids})}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("apply", _params, %{assigns: %{confirm: %{action: action, id: id}}} = socket) do
    admin = socket.assigns.current_user

    result =
      case action do
        "enable" -> Plugins.enable(id, admin)
        "disable" -> Plugins.disable(id, admin)
        "uninstall" -> with :ok <- Plugins.uninstall(id, admin), do: {:ok, [id]}
      end

    case result do
      {:ok, ids} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{past(action)}: #{Enum.join(ids, ", ")}.")
         |> assign(:confirm, nil)
         |> load()}

      {:error, message} ->
        {:noreply, socket |> put_flash(:error, message) |> assign(:confirm, nil)}
    end
  end

  defp past("enable"), do: "Enabled"
  defp past("disable"), do: "Disabled"
  defp past("uninstall"), do: "Uninstalled"

  @doc false
  def status_badge(assigns) do
    ~H"""
    <%= case @status do %>
      <% :enabled -> %>
        <span class="badge badge-success badge-sm">enabled</span>
      <% :disabled -> %>
        <span class="badge badge-ghost badge-sm">disabled</span>
      <% :broken -> %>
        <span class="badge badge-error badge-sm">broken</span>
      <% {:auto_disabled, _reason} -> %>
        <span class="badge badge-error badge-sm">turned off: failing</span>
      <% {:suspended, ids} -> %>
        <span class="badge badge-warning badge-sm">suspended: waiting for {Enum.join(ids, ", ")}</span>
    <% end %>
    """
  end

  @doc false
  def dependency_list(assigns) do
    ~H"""
    <ul class="flex flex-wrap gap-1">
      <li :for={dep <- @dependencies} class={["badge badge-sm", dependency_class(dep.state)]}>
        {dep.id} {dep.requirement}{if dep.optional, do: " (optional)"}{dependency_state(dep.state)}
      </li>
    </ul>
    """
  end

  defp dependency_class(:active), do: "badge-outline"
  defp dependency_class(:inactive), do: "badge-warning"
  defp dependency_class(_problem), do: "badge-error"

  defp dependency_state(:active), do: ""
  defp dependency_state(:inactive), do: ": inactive"
  defp dependency_state(:missing), do: ": missing"
  defp dependency_state({:incompatible, version}), do: ": #{version} installed"

  defp enabled?(%{status: status}), do: status == :enabled or match?({:suspended, _}, status)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Plugins" navigate={~p"/staff/plugins"}>
        <:subtitle>
          Core plugins ship with Firefly; uploaded plugins run sandboxed, with only the permissions they request.
        </:subtitle>
      </.page_header>

      <section id="plugin-upload" class="card border border-base-300 bg-base-100 mb-6">
        <form id="upload-form" phx-submit="upload" phx-change="validate" class="card-body gap-2">
          <h2 class="card-title">Upload a plugin</h2>
          <p class="text-sm text-base-content/70">
            A .zip with plugin.json and the plugin's JavaScript. Uploading a newer version of an installed plugin upgrades it.
          </p>
          <div class="flex flex-wrap items-center gap-2">
            <label for={@uploads.bundle.ref} class="label">Bundle</label>
            <.live_file_input upload={@uploads.bundle} class="file-input file-input-sm" />
            <.button>Upload</.button>
          </div>
          <p :for={entry <- @uploads.bundle.entries} class="text-sm">
            {entry.client_name}
            <span :for={error <- upload_errors(@uploads.bundle, entry)} class="text-error">
              {upload_error(error)}
            </span>
          </p>
        </form>
      </section>

      <section
        :if={@preview}
        id="plugin-preview"
        class="card border-2 border-primary bg-base-100 mb-6"
      >
        <div class="card-body gap-3">
          <h2 class="card-title">
            {if @preview.current, do: "Upgrade", else: "Install"} {@manifest.name} {@manifest.version}
          </h2>
          <p :if={@preview.current} class="text-sm">
            Replaces version {@preview.current.version}; settings are kept.
          </p>
          <p class="text-sm">{@manifest.description}</p>
          <p class="text-xs text-base-content/60">
            {@manifest.id} by {@manifest.author} · SHA-256 {@preview.bundle.checksum}
          </p>
          <div>
            <h3 class="font-medium">It asks to</h3>
            <ul id="preview-permissions" class="list-disc pl-5 text-sm">
              <li :for={permission <- @manifest.permissions}>
                <strong>{permission}</strong>: {Host.describe_permission(permission)}
              </li>
              <li :if={@manifest.permissions == []}>Nothing beyond its own settings and logs.</li>
            </ul>
          </div>
          <div :if={@manifest.dependencies != %{} or @manifest.optional_dependencies != %{}}>
            <h3 class="font-medium">Depends on</h3>
            <ul class="text-sm">
              <li :for={{id, requirement} <- @manifest.dependencies}>{id} {requirement}</li>
              <li :for={{id, requirement} <- @manifest.optional_dependencies}>
                {id} {requirement} (optional)
              </li>
            </ul>
          </div>
          <div :if={@preview.problems != []} id="preview-problems" class="alert alert-error">
            <ul>
              <li :for={problem <- @preview.problems}>{problem}</li>
            </ul>
          </div>
          <div class="flex gap-2">
            <button
              id="install-plugin"
              phx-click="install"
              class="btn btn-primary"
              disabled={@preview.problems != []}
            >
              {if @preview.current, do: "Upgrade", else: "Install"}
            </button>
            <button phx-click="cancel_preview" class="btn btn-ghost">Cancel</button>
          </div>
        </div>
      </section>

      <section :if={@confirm} id="plugin-confirm" class="alert alert-warning mb-6 flex-col items-start">
        <p :if={@confirm.action == "uninstall"}>
          Uninstall <strong>{@confirm.id}</strong>? Its bundle, settings, error log, stored data, custom fields, queued events and job schedule are deleted. Its bot's posts stay.
        </p>
        <p :if={@confirm.action != "uninstall"}>
          {String.capitalize(@confirm.action)} <strong>{@confirm.id}</strong>?
          <span :if={length(@confirm.ids) > 1}>
            This also {@confirm.action}s:
            <strong id="confirm-cascade">{Enum.join(@confirm.ids -- [@confirm.id], ", ")}</strong>
            {if @confirm.action == "enable", do: "(it needs them).", else: "(they need it)."}
          </span>
        </p>
        <div class="flex gap-2">
          <button id="confirm-plugin-action" phx-click="apply" class="btn btn-sm btn-primary">
            {String.capitalize(@confirm.action)}
          </button>
          <button phx-click="cancel" class="btn btn-sm btn-ghost">Cancel</button>
        </div>
      </section>

      <p :if={@plugins == []} class="text-base-content/60">No plugins are installed.</p>

      <div class="space-y-4">
        <section
          :for={plugin <- @plugins}
          id={"plugin-#{plugin.id}"}
          class="card border border-base-300 bg-base-100"
        >
          <div class="card-body gap-2">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="card-title">
                <.link navigate={~p"/staff/plugins/#{plugin.id}"} class="link link-hover">
                  {plugin.name}
                </.link>
              </h2>
              <span class="text-sm text-base-content/60">{plugin.version}</span>
              <span class={["badge badge-sm", plugin.source == "core" && "badge-info"]}>
                {if plugin.source == "core", do: "core", else: "uploaded"}
              </span>
              <.status_badge status={plugin.status} />
            </div>
            <p :if={plugin.manifest} class="text-sm">{plugin.manifest.description}</p>
            <div :if={plugin.problems != []} class="alert alert-error py-2 text-sm">
              <ul>
                <li :for={problem <- plugin.problems}>{problem}</li>
              </ul>
            </div>
            <p :if={match?({:auto_disabled, _}, plugin.status)} class="text-sm text-error">
              {elem(plugin.status, 1)}
            </p>
            <div :if={plugin.dependencies != []} class="flex items-center gap-2 text-sm">
              <span class="font-medium">Needs</span>
              <.dependency_list dependencies={plugin.dependencies} />
            </div>
            <p :if={plugin.dependents != []} class="text-sm">
              <span class="font-medium">Needed by</span> {Enum.join(plugin.dependents, ", ")}
            </p>
            <p class="text-xs text-base-content/60">
              {plugin.stats.calls} calls, {plugin.stats.failures} failed, {plugin.stats.average_ms} ms on average (this server)
            </p>
            <div class="flex gap-2">
              <button
                :if={!enabled?(plugin)}
                phx-click="confirm"
                phx-value-action="enable"
                phx-value-id={plugin.id}
                class="btn btn-sm btn-primary"
              >
                Enable
              </button>
              <button
                :if={enabled?(plugin)}
                phx-click="confirm"
                phx-value-action="disable"
                phx-value-id={plugin.id}
                class="btn btn-sm"
              >
                Disable
              </button>
              <.link navigate={~p"/staff/plugins/#{plugin.id}"} class="btn btn-sm btn-ghost">
                Settings and errors
              </.link>
              <button
                :if={plugin.source == "upload"}
                phx-click="confirm"
                phx-value-action="uninstall"
                phx-value-id={plugin.id}
                class="btn btn-sm btn-ghost text-error"
              >
                Uninstall
              </button>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp upload_error(:too_large), do: "is over 1 MB"
  defp upload_error(:not_accepted), do: "isn't a .zip"
  defp upload_error(:too_many_files), do: "one bundle at a time"
  defp upload_error(error), do: to_string(error)
end
