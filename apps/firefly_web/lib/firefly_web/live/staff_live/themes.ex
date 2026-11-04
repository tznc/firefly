defmodule FireflyWeb.StaffLive.Themes do
  @moduledoc """
  The themes admin (admins only; see `Firefly.Themes`): the themes and
  theme components, which theme is the site's default and which members
  may pick, creating new ones, and importing a JSON bundle from a file, a
  URL or a GitHub repository.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{SiteSettings, Themes}
  alias Firefly.Themes.Theme

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_themes) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Themes"))
       |> assign(:form, to_form(Themes.change_theme(%Theme{})))
       # JSON, told apart by its content.
       |> allow_upload(:bundle, accept: :any, max_entries: 1, max_file_size: 10_000_000)
       |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket) do
    socket
    |> assign(:themes, Themes.list_themes())
    |> assign(:components, Themes.list_components())
    |> assign(:default_id, SiteSettings.get("default_theme_id"))
  end

  @impl true
  def handle_event(event, params, socket) do
    if can?(socket.assigns.current_user, :manage_themes),
      do: theme_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}
  end

  defp theme_event("create", %{"theme" => params}, socket) do
    case Themes.create_theme(params, socket.assigns.current_user) do
      {:ok, theme} -> {:noreply, push_navigate(socket, to: ~p"/staff/themes/#{theme.id}")}
      {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp theme_event("validate_upload", _params, socket), do: {:noreply, socket}

  defp theme_event("import_file", _params, socket) do
    json =
      consume_uploaded_entries(socket, :bundle, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case json do
      [json] -> imported(socket, Themes.import(json, socket.assigns.current_user))
      [] -> {:noreply, put_flash(socket, :error, gettext("Pick a theme bundle (JSON)."))}
    end
  end

  defp theme_event("import_url", %{"url" => url}, socket),
    do: imported(socket, Themes.import_from_url(url, socket.assigns.current_user))

  defp imported(socket, {:ok, theme}) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Imported %{name}.", name: theme.name))
     |> push_navigate(to: ~p"/staff/themes/#{theme.id}")}
  end

  defp imported(socket, {:error, %Ecto.Changeset{} = changeset}) do
    details =
      Enum.map_join(changeset.errors, "; ", fn {field, {text, _}} -> "#{field} #{text}" end)

    {:noreply, put_flash(socket, :error, gettext("Not imported: %{details}", details: details))}
  end

  defp imported(socket, {:error, message}),
    do: {:noreply, put_flash(socket, :error, Themes.message(message))}

  attr :theme, :any, required: true
  attr :default_id, :integer, default: nil

  defp theme_row(assigns) do
    ~H"""
    <li id={"theme-#{@theme.id}"} class="list-row items-center">
      <.icon name={if @theme.component, do: "hero-puzzle-piece", else: "hero-paint-brush"} class="size-5 opacity-70" />
      <div>
        <.link navigate={~p"/staff/themes/#{@theme.id}"} class="link font-medium">{@theme.name}</.link>
        <p :if={@theme.description} class="text-xs text-base-content/70">{@theme.description}</p>
      </div>
      <div class="flex flex-wrap gap-1">
        <span :if={@theme.id == @default_id} class="badge badge-sm badge-primary">{gettext("default")}</span>
        <span :if={@theme.user_selectable} class="badge badge-sm">{gettext("members can pick it")}</span>
        <span :if={@theme.allow_scripts} class="badge badge-sm badge-warning">{gettext("runs scripts")}</span>
        <span :if={@theme.components != []} class="badge badge-sm badge-ghost">
          {ngettext("1 component", "%{count} components", length(@theme.components))}
        </span>
      </div>
    </li>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title={gettext("Themes")} navigate={~p"/staff/themes"}>
        <:subtitle>{gettext("Colors, CSS and HTML for the whole site. Preview a theme yourself before making it the default.")}</:subtitle>
      </.page_header>

      <p :if={@default_id == 0} id="builtin-default" class="text-sm text-base-content/70">
        {gettext("The site uses the built-in look: no theme is the default.")}
      </p>

      <section class="space-y-2">
        <h2 class="text-lg font-semibold">{gettext("Themes")}</h2>
        <p :if={@themes == []} class="text-base-content/70">{gettext("No themes yet.")}</p>
        <ul id="themes" class="list rounded-box border border-base-300 bg-base-100">
          <.theme_row :for={theme <- @themes} theme={theme} default_id={@default_id} />
        </ul>
      </section>

      <section class="space-y-2">
        <h2 class="text-lg font-semibold">{gettext("Theme components")}</h2>
        <p :if={@components == []} class="text-base-content/70">
          {gettext("Components are pieces several themes can include, like a banner or a font.")}
        </p>
        <ul id="components" class="list rounded-box border border-base-300 bg-base-100">
          <.theme_row :for={component <- @components} theme={component} />
        </ul>
      </section>

      <section class="card border border-base-300 bg-base-100">
        <.form for={@form} id="theme-form" phx-submit="create" class="card-body gap-2">
          <h2 class="card-title">{gettext("New theme")}</h2>
          <.input field={@form[:name]} type="text" label={gettext("Name")} />
          <.input field={@form[:component]} type="checkbox" label={gettext("It's a component (themes include it)")} />
          <div><.button variant="primary">{gettext("Create")}</.button></div>
        </.form>
      </section>

      <section class="card border border-base-300 bg-base-100">
        <div class="card-body gap-3">
          <h2 class="card-title">{gettext("Import")}</h2>
          <form id="import-file-form" phx-submit="import_file" phx-change="validate_upload" class="flex flex-wrap items-end gap-2">
            <.live_file_input upload={@uploads.bundle} class="file-input" aria-label={gettext("Theme bundle")} />
            <.button variant="primary">{gettext("Import file")}</.button>
          </form>
          <form id="import-url-form" phx-submit="import_url" class="flex flex-wrap items-end gap-2">
            <.input
              name="url"
              value=""
              type="url"
              label={gettext("Or from a URL or GitHub repository")}
              placeholder={gettext("https://github.com/owner/repo")}
            />
            <.button variant="primary" class="mb-2">{gettext("Import from URL")}</.button>
          </form>
          <p class="text-xs text-base-content/70">
            {gettext("A GitHub repository's firefly-theme.json is read from its default branch. Imported themes never run scripts until you allow it.")}
          </p>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
