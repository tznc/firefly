defmodule FireflyWeb.StaffLive.Theme do
  @moduledoc """
  One theme or theme component (admins only; see `Firefly.Themes`): its
  name, description and whether members may pick it; its light and dark
  color schemes (each daisyUI token, blank for the built-in value), with
  a warning for every text color that falls below WCAG AA on its
  background as the colors are edited; its CSS and head, header and
  footer HTML; whether its HTML may run scripts (a logged admin decision);
  the components a theme includes; and its assets (images and fonts the
  CSS names as `theme-asset(name)`). From here admins preview it, make it
  the default, export it or delete it.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{SiteSettings, Themes}
  alias Firefly.Themes.{Palette, Theme}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if can?(socket.assigns.current_user, :manage_themes) do
      theme = Themes.get_theme!(id)

      {:ok,
       socket
       |> assign(:page_title, theme.name)
       |> assign(:all_components, Themes.list_components())
       |> allow_upload(:asset,
         accept: :any,
         max_entries: 1,
         max_file_size: Firefly.Uploads.max_size()
       )
       |> load(theme)}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket, %Theme{} = theme) do
    socket
    |> assign(:theme, theme)
    |> assign(:default?, SiteSettings.get("default_theme_id") == theme.id)
    |> assign(:colors, theme.colors || %{})
    |> assign(:warnings, Themes.contrast_warnings(theme.colors))
    |> assign(:form, to_form(Themes.change_theme(theme)))
  end

  defp reload(socket), do: load(socket, Themes.get_theme!(socket.assigns.theme.id))

  @impl true
  def handle_event(event, params, socket) do
    if can?(socket.assigns.current_user, :manage_themes),
      do: theme_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}
  end

  # Colors as edited, for the contrast warnings; nothing is saved.
  defp theme_event("validate", %{"theme" => params}, socket) do
    colors = colors(params)

    {:noreply,
     socket
     |> assign(:colors, colors)
     |> assign(:warnings, Themes.contrast_warnings(colors))}
  end

  defp theme_event("save", %{"theme" => params}, socket) do
    params = Map.put(params, "colors", colors(params))

    case Themes.update_theme(socket.assigns.theme, params, socket.assigns.current_user) do
      {:ok, _theme} ->
        {:noreply, socket |> put_flash(:info, gettext("Theme saved.")) |> reload()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Not saved: fix what's marked."))
         |> assign(:form, to_form(changeset))}
    end
  end

  defp theme_event("allow_scripts", %{"allow" => allow}, socket) do
    {:ok, _} =
      Themes.set_allow_scripts(socket.assigns.theme, allow == "true", socket.assigns.current_user)

    message =
      if allow == "true",
        do: gettext("Its HTML may run scripts now."),
        else: gettext("Its scripts are off.")

    {:noreply, socket |> put_flash(:info, message) |> reload()}
  end

  defp theme_event("components", params, socket) do
    {:ok, _} =
      Themes.set_components(
        socket.assigns.theme,
        params["component_ids"] || [],
        socket.assigns.current_user
      )

    {:noreply, socket |> put_flash(:info, gettext("Components saved.")) |> reload()}
  end

  defp theme_event("make_default", %{"default" => default}, socket) do
    theme = if default == "true", do: socket.assigns.theme

    case Themes.make_default(theme, socket.assigns.current_user) do
      {:ok, _} ->
        message =
          if theme,
            do: gettext("%{name} is the site's theme now.", name: theme.name),
            else: gettext("The site uses the built-in look again.")

        {:noreply, socket |> put_flash(:info, message) |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Themes.message(reason))}
    end
  end

  defp theme_event("delete", _params, socket) do
    {:ok, _} = Themes.delete_theme(socket.assigns.theme, socket.assigns.current_user)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Theme deleted."))
     |> push_navigate(to: ~p"/staff/themes")}
  end

  defp theme_event("validate_asset", _params, socket), do: {:noreply, socket}

  defp theme_event("add_asset", %{"name" => name}, socket) do
    %{theme: theme, current_user: admin} = socket.assigns

    result =
      case uploaded_entries(socket, :asset) do
        {[_entry], []} ->
          [result] =
            consume_uploaded_entries(socket, :asset, fn %{path: path}, entry ->
              {:ok, Themes.add_asset(theme, name, path, entry.client_name, admin)}
            end)

          result

        _none ->
          {:error, gettext("Pick a file.")}
      end

    case result do
      {:ok, asset} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Added %{name}.", name: asset.name)) |> reload()}

      {:error, %Ecto.Changeset{} = changeset} ->
        details = Enum.map_join(changeset.errors, "; ", fn {f, {t, _}} -> "#{f} #{t}" end)
        {:noreply, put_flash(socket, :error, details)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp theme_event("remove_asset", %{"id" => id}, socket) do
    case Themes.remove_asset(socket.assigns.theme, id, socket.assigns.current_user) do
      {:ok, _} -> {:noreply, reload(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Themes.message(reason))}
    end
  end

  # The colors posted, without those left at the built-in value.
  defp colors(params) do
    for scheme <- Palette.schemes(), into: %{} do
      posted = get_in(params, ["colors", scheme]) || %{}

      changed =
        for {token, value} <- posted,
            token in Palette.tokens(),
            value = String.downcase(String.trim(value)),
            value != "" and value != Palette.defaults()[scheme][token],
            into: %{},
            do: {token, value}

      {scheme, changed}
    end
  end

  defp color(colors, scheme, token),
    do: get_in(colors, [scheme, token]) || Palette.defaults()[scheme][token]

  defp scheme_label("light"), do: gettext("Light")
  defp scheme_label("dark"), do: gettext("Dark")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title={@theme.name} navigate={~p"/staff/themes/#{@theme.id}"}>
        <:subtitle>
          {if @theme.component, do: gettext("A theme component"), else: gettext("A theme")}
          · {gettext("version %{version}", version: @theme.version)}
          <span :if={@default?} class="badge badge-sm badge-primary">{gettext("default")}</span>
        </:subtitle>
        <:actions>
          <.link
            :if={!@theme.component}
            id="preview-theme"
            href={~p"/staff/themes/#{@theme.id}/preview"}
            method="post"
            class="btn btn-sm"
          >
            {gettext("Preview")}
          </.link>
          <button
            :if={!@theme.component and !@default?}
            phx-click="make_default"
            phx-value-default="true"
            data-confirm={gettext("Every member who hasn't picked a theme will see it. Go ahead?")}
            class="btn btn-sm btn-primary"
          >
            {gettext("Make default")}
          </button>
          <button :if={@default?} phx-click="make_default" phx-value-default="false" class="btn btn-sm">
            {gettext("Use the built-in look")}
          </button>
          <.link href={~p"/staff/themes/#{@theme.id}/export"} class="btn btn-sm">{gettext("Export")}</.link>
        </:actions>
      </.page_header>

      <.form for={@form} id="theme-form" phx-change="validate" phx-submit="save" class="space-y-6">
        <section class="card border border-base-300 bg-base-100">
          <div class="card-body gap-2">
            <h2 class="card-title">{gettext("About")}</h2>
            <.input field={@form[:name]} type="text" label={gettext("Name")} />
            <.input field={@form[:description]} type="textarea" rows="2" label={gettext("Description")} />
            <.input
              :if={!@theme.component}
              field={@form[:user_selectable]}
              type="checkbox"
              label={gettext("Members can pick it in their interface settings")}
            />
          </div>
        </section>

        <section id="colors" class="card border border-base-300 bg-base-100">
          <div class="card-body gap-3">
            <h2 class="card-title">{gettext("Colors")}</h2>
            <p class="text-sm text-base-content/70">
              {gettext("Each scheme's daisyUI colors. Colors left as they are keep the built-in value.")}
            </p>
            <div id="contrast-warnings" :if={@warnings != []} role="alert" class="alert alert-warning">
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <div>
                <p class="font-semibold">{gettext("Some text won't be readable enough (WCAG AA needs 4.5:1):")}</p>
                <ul class="list-disc pl-5 text-sm">
                  <li :for={warning <- @warnings}>
                    {gettext("%{scheme}: %{foreground} on %{background} is %{ratio}:1",
                      scheme: scheme_label(warning.scheme),
                      foreground: warning.foreground,
                      background: warning.background,
                      ratio: warning.ratio
                    )}
                  </li>
                </ul>
              </div>
            </div>
            <p :if={@warnings == []} id="contrast-ok" class="text-sm text-success">
              <.icon name="hero-check-circle" class="size-4" /> {gettext("Every text color meets WCAG AA.")}
            </p>
            <div class="grid gap-4 md:grid-cols-2">
              <fieldset :for={scheme <- Palette.schemes()} class="space-y-1">
                <legend class="font-semibold">{scheme_label(scheme)}</legend>
                <label :for={token <- Palette.tokens()} class="flex items-center justify-between gap-2 text-sm" for={"color-#{scheme}-#{token}"}>
                  <span>{token}</span>
                  <input
                    type="color"
                    id={"color-#{scheme}-#{token}"}
                    name={"theme[colors][#{scheme}][#{token}]"}
                    value={color(@colors, scheme, token)}
                    class="h-8 w-14 cursor-pointer rounded border border-base-300"
                  />
                </label>
              </fieldset>
            </div>
          </div>
        </section>

        <section class="card border border-base-300 bg-base-100">
          <div class="card-body gap-2">
            <h2 class="card-title">{gettext("CSS")}</h2>
            <p class="text-sm text-base-content/70">
              {gettext("Up to 100 KB. Name an asset as theme-asset(name), e.g. background: theme-asset(hero).")}
            </p>
            <.input field={@form[:css]} type="textarea" rows="10" label={gettext("Custom CSS")} class="textarea w-full font-mono text-sm" />
          </div>
        </section>

        <section class="card border border-base-300 bg-base-100">
          <div class="card-body gap-2">
            <h2 class="card-title">{gettext("HTML")}</h2>
            <p class="text-sm text-base-content/70">
              {if @theme.allow_scripts,
                do: gettext("This theme may run scripts: its HTML is used as written."),
                else: gettext("Scripts, event handlers and inline styles are removed.")}
            </p>
            <.input field={@form[:head_html]} type="textarea" rows="4" label={gettext("In the page's head")} class="textarea w-full font-mono text-sm" />
            <.input field={@form[:header_html]} type="textarea" rows="4" label={gettext("At the top of every page")} class="textarea w-full font-mono text-sm" />
            <.input field={@form[:footer_html]} type="textarea" rows="4" label={gettext("At the bottom of every page")} class="textarea w-full font-mono text-sm" />
          </div>
        </section>

        <div class="flex justify-end">
          <.button variant="primary" phx-disable-with={gettext("Saving...")}>{gettext("Save theme")}</.button>
        </div>
      </.form>

      <section id="scripts" class="card border border-warning/50 bg-base-100">
        <div class="card-body gap-2">
          <h2 class="card-title">{gettext("Scripts")}</h2>
          <p class="text-sm text-base-content/70">
            {gettext("Scripts in a theme's HTML run on every page, for every member, with their session. Only allow them for code you trust. The change is recorded in the staff log.")}
          </p>
          <div>
            <button
              :if={!@theme.allow_scripts}
              phx-click="allow_scripts"
              phx-value-allow="true"
              data-confirm={gettext("Let this theme run scripts on every page?")}
              class="btn btn-sm btn-warning"
            >
              {gettext("Allow scripts")}
            </button>
            <button :if={@theme.allow_scripts} phx-click="allow_scripts" phx-value-allow="false" class="btn btn-sm">
              {gettext("Turn scripts off")}
            </button>
          </div>
        </div>
      </section>

      <section :if={!@theme.component} id="theme-components" class="card border border-base-300 bg-base-100">
        <form id="components-form" phx-submit="components" class="card-body gap-2">
          <h2 class="card-title">{gettext("Components")}</h2>
          <p :if={@all_components == []} class="text-sm text-base-content/70">{gettext("No components yet.")}</p>
          <input type="hidden" name="component_ids[]" value="" />
          <label :for={component <- @all_components} class="flex items-center gap-2" for={"component-#{component.id}"}>
            <input
              type="checkbox"
              id={"component-#{component.id}"}
              name="component_ids[]"
              value={component.id}
              checked={Enum.any?(@theme.components, &(&1.id == component.id))}
              class="checkbox checkbox-sm"
            />
            {component.name}
          </label>
          <div :if={@all_components != []}><.button variant="primary">{gettext("Save components")}</.button></div>
        </form>
      </section>

      <section id="assets" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-2">
          <h2 class="card-title">{gettext("Assets")}</h2>
          <ul class="space-y-1 text-sm">
            <li :for={asset <- @theme.assets} id={"asset-#{asset.id}"} class="flex items-center gap-2">
              <code>theme-asset({asset.name})</code>
              <a href={Firefly.Uploads.url(asset.upload)} class="link">{asset.upload.filename}</a>
              <button
                phx-click="remove_asset"
                phx-value-id={asset.id}
                aria-label={gettext("Remove %{name}", name: asset.name)}
                class="btn btn-ghost btn-xs"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </li>
          </ul>
          <form id="asset-form" phx-submit="add_asset" phx-change="validate_asset" class="flex flex-wrap items-end gap-2">
            <.input name="name" value="" label={gettext("Asset name")} placeholder={gettext("hero")} />
            <.live_file_input upload={@uploads.asset} class="file-input mb-2" aria-label={gettext("Image or font file")} />
            <.button variant="primary" class="mb-2">{gettext("Add asset")}</.button>
          </form>
          <p class="text-xs text-base-content/70">{gettext("PNG, JPEG, GIF or WebP images, WOFF or WOFF2 fonts.")}</p>
        </div>
      </section>

      <section class="card border border-error/40 bg-base-100">
        <div class="card-body">
          <div>
            <button
              phx-click="delete"
              data-confirm={gettext("Delete %{name}? This can't be undone.", name: @theme.name)}
              class="btn btn-sm btn-error"
            >
              {gettext("Delete theme")}
            </button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
