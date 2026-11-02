defmodule FirestormWeb.Web.StaffLive.Plugin do
  @moduledoc """
  One plugin (admins only): what it is and may do, its settings (a form
  generated from its manifest's settings schema), statistics and error log.
  Enabling and disabling are on the plugins page, which confirms cascades.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  import FirestormWeb.Web.StaffLive.Plugins, only: [status_badge: 1, dependency_list: 1]

  alias FirestormWeb.Plugin.Host
  alias FirestormWeb.Plugins
  alias FirestormWeb.Plugins.Health

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    plugin = can?(socket.assigns.current_user, :manage_plugins) && Plugins.describe(id)

    cond do
      plugin ->
        {:ok, socket |> assign(:page_title, plugin.name) |> load(plugin)}

      plugin == false ->
        {:ok,
         socket
         |> put_flash(:error, denied_message(socket.assigns.current_user))
         |> push_navigate(to: ~p"/")}

      true ->
        {:ok,
         socket
         |> put_flash(:error, "No plugin #{id} is installed.")
         |> push_navigate(to: ~p"/staff/plugins")}
    end
  end

  defp load(socket, plugin) do
    socket
    |> assign(:plugin, plugin)
    |> assign(:errors, Health.errors(plugin.id))
    |> assign_form(form_values(plugin.settings || %{}), %{})
  end

  @impl true
  def handle_event("save", params, socket) do
    plugin = socket.assigns.plugin
    values = Map.get(params, "settings", %{})

    case Plugins.update_settings(plugin.id, values, socket.assigns.current_user) do
      {:ok, _values} ->
        {:noreply,
         socket
         |> put_flash(:info, "Settings saved.")
         |> load(Plugins.describe(plugin.id))}

      {:error, errors} ->
        {:noreply,
         socket
         |> put_flash(:error, "Some settings are invalid; nothing was saved.")
         |> assign_form(values, errors)}
    end
  end

  def handle_event("fail_mode", %{"mode" => mode}, socket) when mode in ["open", "closed"] do
    id = socket.assigns.plugin.id
    :ok = Plugins.set_fail_closed(id, mode == "closed", socket.assigns.current_user)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "If its moderation fails, posting now #{if mode == "closed", do: "stops", else: "goes ahead"}."
     )
     |> load(Plugins.describe(id))}
  end

  defp form_values(values), do: Map.new(values, fn {key, value} -> {key, to_string(value)} end)

  defp assign_form(socket, values, errors) do
    errors = Enum.map(errors, fn {key, message} -> {key, {message, []}} end)
    assign(socket, :form, to_form(values, as: :settings, errors: errors, action: :validate))
  end

  defp fail_closed?(plugin), do: (plugin.row && plugin.row.fail_closed) || false

  defp input_type("boolean"), do: "checkbox"
  defp input_type("integer"), do: "number"
  defp input_type("text"), do: "textarea"
  defp input_type("enum"), do: "select"
  defp input_type("string"), do: "text"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title={@plugin.name} navigate={~p"/staff/plugins/#{@plugin.id}"}>
        <:subtitle>
          {@plugin.id} {@plugin.version} · {if @plugin.source == "core",
            do: "core plugin",
            else: "uploaded plugin"}
        </:subtitle>
        <:actions>
          <.link navigate={~p"/staff/plugins"} class="btn btn-sm btn-ghost">All plugins</.link>
        </:actions>
      </.page_header>

      <div class="space-y-6">
        <section id="plugin-about" class="card border border-base-300 bg-base-100">
          <div class="card-body gap-2">
            <div class="flex items-center gap-2">
              <.status_badge status={@plugin.status} />
              <span :if={@plugin.manifest && @plugin.manifest.author != ""} class="text-sm">
                by {@plugin.manifest.author}
              </span>
            </div>
            <p :if={@plugin.manifest}>{@plugin.manifest.description}</p>
            <div :if={@plugin.problems != []} class="alert alert-error py-2 text-sm">
              <ul>
                <li :for={problem <- @plugin.problems}>{problem}</li>
              </ul>
            </div>
            <div :if={@plugin.manifest}>
              <h3 class="font-medium">Permissions</h3>
              <ul id="plugin-permissions" class="list-disc pl-5 text-sm">
                <li :for={permission <- @plugin.manifest.permissions}>
                  <strong>{permission}</strong>: {Host.describe_permission(permission)}
                </li>
                <li :if={@plugin.manifest.permissions == []}>None.</li>
              </ul>
            </div>
            <div :if={@plugin.dependencies != []} class="flex items-center gap-2 text-sm">
              <span class="font-medium">Needs</span>
              <.dependency_list dependencies={@plugin.dependencies} />
            </div>
            <p :if={@plugin.dependents != []} class="text-sm">
              <span class="font-medium">Needed by</span> {Enum.join(@plugin.dependents, ", ")}
            </p>
            <p :if={@plugin.row && @plugin.row.checksum} class="text-xs text-base-content/60">
              Bundle SHA-256 {@plugin.row.checksum}
            </p>
          </div>
        </section>

        <section
          :if={@plugin.manifest && @plugin.manifest.settings != []}
          id="plugin-settings"
          class="card border border-base-300 bg-base-100"
        >
          <.form for={@form} id="plugin-settings-form" phx-submit="save" class="card-body gap-2">
            <h2 class="card-title">Settings</h2>
            <div :for={setting <- @plugin.manifest.settings}>
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
            <div><.button variant="primary" phx-disable-with="Saving...">Save settings</.button></div>
          </.form>
        </section>

        <section
          :if={@plugin.manifest && "moderate_post" in @plugin.manifest.hooks}
          id="plugin-moderation"
          class="card border border-base-300 bg-base-100"
        >
          <div class="card-body gap-2">
            <h2 class="card-title">Moderation</h2>
            <p class="text-sm">
              This plugin checks new posts before they're saved. If it fails or takes too long:
            </p>
            <div class="join">
              <button
                phx-click="fail_mode"
                phx-value-mode="open"
                class={["btn btn-sm join-item", !fail_closed?(@plugin) && "btn-active btn-primary"]}
              >
                Let posts through (fail open)
              </button>
              <button
                phx-click="fail_mode"
                phx-value-mode="closed"
                class={["btn btn-sm join-item", fail_closed?(@plugin) && "btn-active btn-primary"]}
              >
                Refuse posts (fail closed)
              </button>
            </div>
          </div>
        </section>

        <section id="plugin-stats" class="card border border-base-300 bg-base-100">
          <div class="card-body gap-2">
            <h2 class="card-title">Health</h2>
            <p class="text-sm">
              On this server since it started: {@plugin.stats.calls} calls, {@plugin.stats.failures} failed, {@plugin.stats.average_ms} ms on average.
            </p>
            <h3 class="font-medium">Recent errors</h3>
            <p :if={@errors == []} class="text-sm text-base-content/60">None.</p>
            <ul :if={@errors != []} id="plugin-errors" class="space-y-2">
              <li :for={error <- @errors} id={"plugin-error-#{error.id}"} class="text-sm">
                <div class="flex gap-2">
                  <span class="badge badge-sm badge-error">{error.kind}</span>
                  <span class="font-mono">{error.hook}</span>
                  <.time_ago at={error.inserted_at} id={"plugin-error-#{error.id}-at"} />
                </div>
                <pre class="whitespace-pre-wrap text-xs text-base-content/70">{error.message}</pre>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
