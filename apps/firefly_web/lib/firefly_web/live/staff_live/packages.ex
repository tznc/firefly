defmodule FireflyWeb.StaffLive.Packages do
  @moduledoc """
  Packages (admins only; see `Firefly.Packages`): every plugin and theme
  installed on the site in one list, filtered by tag (`?tag=theme` for
  the themes), and the one way to install them: upload a package (or an
  old theme JSON bundle), or fetch one from a URL or GitHub repository.

  Before installing, it shows what the package is: for plugin code, the
  permissions it requests in plain words naming the hosts it may send
  data to (an upgrade highlights what the new version asks for that the
  installed one didn't); for a theme, the themes it creates or updates,
  and a confirm to replace them when an admin edited them since.
  Enabling, disabling and uninstalling go through a confirm step that
  lists every package the change cascades to. `/staff/themes` stays the
  theme editor and picker.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Packages, Plugins}
  alias Firefly.Packages.Archive
  alias Firefly.Plugin.{Host, Manifest}

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_plugins) do
      {:ok,
       socket
       |> assign(:page_title, "Packages")
       |> assign(preview: nil, confirm: nil, overwrite: false, grant: false)
       # A .zip, or an old theme bundle's JSON: told apart by content.
       |> allow_upload(:package, accept: :any, max_entries: 1, max_file_size: Archive.max_size())}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tag = if params["tag"] in [nil, ""], do: nil, else: params["tag"]
    {:noreply, socket |> assign(:tag, tag) |> load()}
  end

  defp load(socket) do
    socket
    |> assign(:packages, Packages.list(socket.assigns.tag))
    |> assign(:tags, Packages.tags())
  end

  @impl true
  def handle_event(event, params, socket) do
    if can?(socket.assigns.current_user, :manage_plugins),
      do: package_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}
  end

  defp package_event("validate", _params, socket), do: {:noreply, socket}

  defp package_event("upload", _params, socket) do
    case consume_uploaded_entries(socket, :package, fn %{path: path}, _entry ->
           {:ok, Packages.read(File.read!(path))}
         end) do
      [read] -> previewed(socket, read, nil)
      [] -> {:noreply, put_flash(socket, :error, "Choose a package (.zip) to upload.")}
    end
  end

  defp package_event("fetch", %{"url" => url}, socket),
    do: previewed(socket, Packages.fetch(url), String.trim(url))

  defp package_event("confirm_options", params, socket) do
    {:noreply,
     assign(socket, overwrite: params["overwrite"] == "true", grant: params["grant"] == "true")}
  end

  defp package_event("install", _params, %{assigns: %{preview: %{archive: archive}}} = socket) do
    %{current_user: admin, preview: preview, overwrite: overwrite, grant: grant} = socket.assigns
    opts = [overwrite: overwrite, grant_theme: grant, source_url: preview.source_url]

    case Packages.install(archive, admin, opts) do
      {:ok, _package} ->
        manifest = archive.manifest

        verb =
          cond do
            preview.current -> "upgraded"
            Manifest.plugin?(manifest) -> "installed (disabled)"
            true -> "installed"
          end

        {:noreply,
         socket
         |> put_flash(:info, "#{manifest.name} #{manifest.version} #{verb}.")
         |> assign(:preview, nil)
         |> load()}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp package_event("cancel_preview", _params, socket),
    do: {:noreply, assign(socket, :preview, nil)}

  defp package_event("confirm", %{"action" => action, "id" => id}, socket)
       when action in ~w(enable disable uninstall) do
    plan =
      case action do
        "enable" -> Plugins.enable_plan(id)
        "disable" -> Plugins.disable_plan(id)
        "uninstall" -> with :ok <- Packages.uninstall_check(id), do: {:ok, [id]}
      end

    case plan do
      {:ok, ids} -> {:noreply, assign(socket, :confirm, %{action: action, id: id, ids: ids})}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp package_event("cancel", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  defp package_event("apply", _params, %{assigns: %{confirm: %{action: action, id: id}}} = socket) do
    admin = socket.assigns.current_user

    result =
      case action do
        "enable" -> Plugins.enable(id, admin)
        "disable" -> Plugins.disable(id, admin)
        "uninstall" -> with :ok <- Packages.uninstall(id, admin), do: {:ok, [id]}
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

  defp previewed(socket, {:ok, archive}, source_url) do
    preview = archive |> Packages.preview() |> Map.put(:source_url, source_url)
    previous = preview.current && Manifest.parse(preview.current.manifest, "upload")

    {:noreply,
     assign(socket,
       preview: preview,
       manifest: archive.manifest,
       previous: match?({:ok, _}, previous) && elem(previous, 1),
       overwrite: false,
       grant: false,
       confirm: nil
     )}
  end

  defp previewed(socket, {:error, message}, _url),
    do: {:noreply, put_flash(socket, :error, message)}

  defp past("enable"), do: "Enabled"
  defp past("disable"), do: "Disabled"
  defp past("uninstall"), do: "Uninstalled"

  @doc """
  The inputs for a settings schema (see `Firefly.Plugin.Settings`): a
  plugin's, or a theme package's.
  """
  attr(:form, :any, required: true)
  attr(:settings, :list, required: true)

  def setting_fields(assigns) do
    ~H"""
    <div :for={setting <- @settings}>
      <.input
        field={@form[setting.key]}
        type={input_type(setting.type)}
        label={setting.label}
        options={setting.choices}
        checked={setting.type == "boolean" && @form.params[setting.key] == "true"}
        min={setting.min}
        max={setting.max}
      />
      <p :if={setting.help != ""} class="-mt-1 text-xs text-base-content/60">{setting.help}</p>
    </div>
    """
  end

  defp input_type("boolean"), do: "checkbox"
  defp input_type("integer"), do: "number"
  defp input_type("text"), do: "textarea"
  defp input_type("enum"), do: "select"
  defp input_type("string"), do: "text"

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

  @doc false
  attr(:id, :string, required: true)
  attr(:manifest, :any, required: true)
  attr(:previous, :any, default: nil)
  attr(:empty, :string, required: true)

  def permission_list(assigns) do
    assigns =
      assign(assigns, :summary, Host.permission_summary(assigns.manifest, assigns.previous))

    ~H"""
    <ul id={@id} class="list-disc pl-5 text-sm space-y-1">
      <li :for={item <- @summary} id={"#{@id}-#{item.permission}"}>
        <span :if={item.new} class="badge badge-warning badge-sm">new</span>
        <span class={item.new && "font-semibold"}>{item.text}</span>
        <span :for={host <- item.hosts} :if={host.new} class="badge badge-warning badge-sm">
          new: {host.name}
        </span>
        <span class="text-xs text-base-content/50">({item.permission})</span>
      </li>
      <li :if={@summary == []}>{@empty}</li>
    </ul>
    """
  end

  defp enabled?(%{status: status}), do: status == :enabled or match?({:suspended, _}, status)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title="Packages" navigate={~p"/staff/packages"}>
        <:subtitle>
          Plugins and themes, shipped the same way. Core plugins ship with Firefly; plugin code from a package runs sandboxed, with only the permissions it requests. Edit and pick themes at
          <.link navigate={~p"/staff/themes"} class="link">Themes</.link>.
        </:subtitle>
      </.page_header>

      <section id="package-install" class="card border border-base-300 bg-base-100 mb-6">
        <div class="card-body gap-3">
          <h2 class="card-title">Install a package</h2>
          <p class="text-sm text-base-content/70">
            A .zip with firefly.json (or a plugin's plugin.json), or an old theme bundle (.json). A newer version of an installed package upgrades it.
          </p>
          <form id="upload-form" phx-submit="upload" phx-change="validate" class="flex flex-wrap items-center gap-2">
            <label for={@uploads.package.ref} class="label">Package file</label>
            <.live_file_input upload={@uploads.package} class="file-input file-input-sm" />
            <%!-- Enabled once the server has the chosen file's entry: a submit
                  before that would find nothing to consume. --%>
            <.button variant="primary" disabled={@uploads.package.entries == []}>Upload</.button>
            <p :for={entry <- @uploads.package.entries} class="text-sm w-full">
              {entry.client_name}
              <span :for={error <- upload_errors(@uploads.package, entry)} class="text-error">
                {upload_error(error)}
              </span>
            </p>
          </form>
          <form id="fetch-form" phx-submit="fetch" class="flex flex-wrap items-end gap-2">
            <.input name="url" value="" type="url" label="Or from a URL or GitHub repository" placeholder="https://github.com/owner/repo" />
            <.button variant="primary" class="mb-2">Fetch</.button>
          </form>
        </div>
      </section>

      <section :if={@preview} id="package-preview" class="card border-2 border-primary bg-base-100 mb-6">
        <div class="card-body gap-3">
          <h2 class="card-title">
            {if @preview.current, do: "Upgrade", else: "Install"} {@manifest.name} {@manifest.version}
          </h2>
          <p :if={@preview.current} class="text-sm">
            Replaces version {@preview.current.version}; settings are kept.
          </p>
          <p class="text-sm">{@manifest.description}</p>
          <div class="flex flex-wrap gap-1">
            <span :for={tag <- @manifest.tags} class="badge badge-sm badge-outline">{tag}</span>
          </div>
          <p class="text-xs text-base-content/60">
            {@manifest.id} by {@manifest.author} · SHA-256 {@preview.archive.checksum}
          </p>
          <div :if={Manifest.plugin?(@manifest)}>
            <h3 class="font-medium">What its plugin code can do</h3>
            <p
              :if={@previous && Host.more_access?(@manifest, @previous)}
              id="preview-more-access"
              class="alert alert-warning py-2 text-sm my-2"
            >
              This version asks for more than version {@preview.current.version}: what's new is highlighted.
            </p>
            <.permission_list
              id="preview-permissions"
              manifest={@manifest}
              previous={@previous || nil}
              empty="Nothing beyond its own settings and logs."
            />
          </div>
          <div :if={Manifest.theme?(@manifest)} id="preview-themes">
            <h3 class="font-medium">Themes it {if @preview.current, do: "updates", else: "adds"}</h3>
            <ul class="text-sm list-disc pl-5">
              <li :for={name <- Packages.theme_names(@manifest)}>{name}</li>
            </ul>
            <p class="text-xs text-base-content/60">Themes from packages never run scripts: their HTML is cleaned.</p>
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
          <form
            :if={@preview.edited != [] or @preview.grant_needed}
            id="confirm-options"
            phx-change="confirm_options"
            class="space-y-2"
          >
            <div :if={@preview.edited != []} id="preview-edited" class="alert alert-warning flex-col items-start">
              <p>
                Changed here since version {@preview.current.version}: <strong>{Enum.join(@preview.edited, ", ")}</strong>. Upgrading replaces those changes.
              </p>
              <label class="flex items-center gap-2" for="overwrite">
                <input type="hidden" name="overwrite" value="false" />
                <input type="checkbox" id="overwrite" name="overwrite" value="true" checked={@overwrite} class="checkbox checkbox-sm" />
                Replace the changes made here
              </label>
            </div>
            <div :if={@preview.grant_needed} id="preview-grant" class="alert alert-info flex-col items-start">
              <p>
                Its plugin also ships theme components: colors and CSS that themes can include. Their HTML is cleaned and they never run scripts.
              </p>
              <label class="flex items-center gap-2" for="grant">
                <input type="hidden" name="grant" value="false" />
                <input type="checkbox" id="grant" name="grant" value="true" checked={@grant} class="checkbox checkbox-sm" />
                Allow its theme components
              </label>
            </div>
          </form>
          <div :if={@preview.problems != []} id="preview-problems" class="alert alert-error">
            <ul>
              <li :for={problem <- @preview.problems}>{problem}</li>
            </ul>
          </div>
          <div class="flex gap-2">
            <button
              id="install-package"
              phx-click="install"
              class="btn btn-primary"
              disabled={
                @preview.problems != [] or (@preview.edited != [] and !@overwrite) or
                  (@preview.grant_needed and !@grant)
              }
            >
              {if @preview.current, do: "Upgrade", else: "Install"}
            </button>
            <button phx-click="cancel_preview" class="btn btn-ghost">Cancel</button>
          </div>
        </div>
      </section>

      <section :if={@confirm} id="package-confirm" class="alert alert-warning mb-6 flex-col items-start">
        <p :if={@confirm.action == "uninstall"}>
          Uninstall <strong>{@confirm.id}</strong>? Its themes are deleted; a plugin's bundle, settings, error log, stored data, custom fields, queued events and job schedule too. Its bot's posts stay.
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
          <button id="confirm-package-action" phx-click="apply" class="btn btn-sm btn-primary">
            {String.capitalize(@confirm.action)}
          </button>
          <button phx-click="cancel" class="btn btn-sm btn-ghost">Cancel</button>
        </div>
      </section>

      <nav id="package-tags" aria-label="Filter by tag" class="flex flex-wrap gap-1 mb-4">
        <.link patch={~p"/staff/packages"} class={["btn btn-xs", is_nil(@tag) && "btn-active"]} aria-current={is_nil(@tag) && "page"}>
          All
        </.link>
        <.link
          :for={tag <- @tags}
          id={"tag-#{tag}"}
          patch={~p"/staff/packages?tag=#{tag}"}
          class={["btn btn-xs", @tag == tag && "btn-active"]}
          aria-current={@tag == tag && "page"}
        >
          {tag}
        </.link>
      </nav>

      <p :if={@packages == []} class="text-base-content/60">
        {if @tag, do: "Nothing installed is tagged #{@tag}.", else: "Nothing is installed."}
      </p>

      <div id="packages" class="space-y-4">
        <section :for={entry <- @packages} id={"package-#{entry.id}"} class="card border border-base-300 bg-base-100">
          <div class="card-body gap-2">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="card-title">
                <.link navigate={entry_path(entry)} class="link link-hover">{entry.name}</.link>
              </h2>
              <span class="text-sm text-base-content/60">{entry.version}</span>
              <span class={["badge badge-sm", entry.kind == :plugin && entry.plugin.source == "core" && "badge-info"]}>
                {kind_label(entry)}
              </span>
              <.status_badge :if={entry.plugin} status={entry.plugin.status} />
              <span :for={tag <- entry.tags} class="badge badge-sm badge-outline">{tag}</span>
            </div>
            <p :if={description(entry)} class="text-sm">{description(entry)}</p>
            <%= if plugin = entry.plugin do %>
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
            <% end %>
            <p :if={entry.themes != []} class="text-sm">
              <span class="font-medium">Themes</span>
              <.link :for={theme <- entry.themes} navigate={~p"/staff/themes/#{theme.id}"} class="link ml-1">{theme.name}</.link>
            </p>
            <div class="flex gap-2">
              <%= if entry.plugin do %>
                <button
                  :if={!enabled?(entry.plugin)}
                  phx-click="confirm"
                  phx-value-action="enable"
                  phx-value-id={entry.id}
                  class="btn btn-sm btn-primary"
                >
                  Enable
                </button>
                <button
                  :if={enabled?(entry.plugin)}
                  phx-click="confirm"
                  phx-value-action="disable"
                  phx-value-id={entry.id}
                  class="btn btn-sm"
                >
                  Disable
                </button>
                <.link navigate={~p"/staff/plugins/#{entry.id}"} class="btn btn-sm btn-ghost">
                  Settings and errors
                </.link>
              <% end %>
              <button
                :if={entry.kind == :theme or entry.plugin.source == "upload"}
                phx-click="confirm"
                phx-value-action="uninstall"
                phx-value-id={entry.id}
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

  defp entry_path(%{plugin: %{id: id}}), do: ~p"/staff/plugins/#{id}"
  defp entry_path(%{themes: [theme | _]}), do: ~p"/staff/themes/#{theme.id}"
  defp entry_path(_entry), do: ~p"/staff/themes"

  defp kind_label(%{kind: :theme}), do: "theme"
  defp kind_label(%{plugin: %{source: "core"}}), do: "core plugin"
  defp kind_label(_entry), do: "plugin"

  defp description(%{plugin: %{manifest: %Manifest{description: text}}}) when text != "", do: text
  defp description(%{package: %{manifest: %{"description" => text}}}) when text != "", do: text
  defp description(_entry), do: nil

  defp upload_error(:too_large), do: "is over #{div(Archive.max_size(), 1024 * 1024)} MB"
  defp upload_error(:too_many_files), do: "one package at a time"
  defp upload_error(error), do: to_string(error)
end
