defmodule FireflyWeb.StaffLive.Settings do
  @moduledoc """
  Site settings (admins only; see `Firefly.SiteSettings`), by category
  (`?category=`, all by default) and section, searched (`?q=`, matching a
  setting's key, label, help or section) and narrowed to the ones changed
  from their default (`?changed=1`). Saving validates every value shown
  for its type and saves the ones that changed.

  Each setting shows its default, can be reset to it, and lists its
  history from the staff log. A setting pinned by an environment variable
  is shown read-only with the variable's name. Secrets are never shown: a
  blank secret field keeps the value. Upload settings (the logo) take an
  image. The settings export as JSON or YAML (`FireflyWeb.SettingsController`)
  and import from either (see `Firefly.SiteSettings.Transfer`).
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{SiteSettings, Uploads}
  alias Firefly.SiteSettings.Transfer

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_site_settings) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Site settings"))
       |> assign(:history, nil)
       # JSON or YAML, told apart by their content (see Transfer.parse/1).
       |> allow_upload(:import, accept: :any, max_entries: 1, max_file_size: 1_000_000)
       |> allow_upload(:logo,
         accept: ~w(.png .jpg .jpeg .gif .webp),
         max_entries: 1,
         max_file_size: Uploads.max_size()
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    categories = Enum.map(SiteSettings.categories(), &elem(&1, 0))

    filters = %{
      "category" => if(params["category"] in categories, do: params["category"], else: ""),
      "q" => String.trim(params["q"] || ""),
      "changed" => if(params["changed"] == "1", do: "1", else: "")
    }

    {:noreply,
     socket
     |> assign(:categories, categories)
     |> assign(:filters, filters)
     |> load()}
  end

  defp load(socket) do
    definitions = visible(socket.assigns.filters)

    socket
    |> assign(:shown, definitions)
    |> assign(:sections, Enum.chunk_by(definitions, & &1.section))
    |> assign_form(form_values(SiteSettings.all()), %{})
  end

  defp visible(filters) do
    words = filters["q"] |> String.downcase() |> String.split(~r/\s+/, trim: true)

    Enum.filter(SiteSettings.definitions(), fn definition ->
      (filters["category"] == "" or definition.category == filters["category"]) and
        (filters["changed"] == "" or SiteSettings.customized?(definition.key)) and
        Enum.all?(words, &String.contains?(search_text(definition), &1))
    end)
  end

  defp search_text(definition),
    do:
      String.downcase(
        Enum.join([definition.key, definition.label, definition.help, definition.section], " ")
      )

  @impl true
  def handle_event("filter", params, socket) do
    query =
      params
      |> Map.take(~w(category q changed))
      |> Map.reject(fn {_key, value} -> value in ["", "false"] end)

    {:noreply, push_patch(socket, to: ~p"/staff/settings?#{query}")}
  end

  def handle_event(event, params, socket) do
    if can?(socket.assigns.current_user, :manage_site_settings),
      do: settings_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}
  end

  defp settings_event("save", %{"settings" => params}, socket) do
    case SiteSettings.update(drop_blank_secrets(params), socket.assigns.current_user) do
      {:ok, changes} ->
        message =
          if changes == %{},
            do: gettext("Nothing changed."),
            else: gettext("Settings saved: %{keys}.", keys: Enum.join(Map.keys(changes), ", "))

        {:noreply, socket |> put_flash(:info, message) |> load()}

      {:error, errors} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Some settings are invalid; nothing was saved."))
         |> assign_form(params, errors)}
    end
  end

  defp settings_event("reset", %{"key" => key}, socket) do
    case SiteSettings.reset(key, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{key} is back to its default.", key: key))
         |> assign(:history, nil)
         |> load()}

      {:error, _unknown} ->
        {:noreply, socket}
    end
  end

  defp settings_event("history", %{"key" => key}, socket) do
    history =
      if match?({^key, _}, socket.assigns.history),
        do: nil,
        else: {key, SiteSettings.history(key)}

    {:noreply, assign(socket, :history, history)}
  end

  defp settings_event("validate_upload", _params, socket), do: {:noreply, socket}

  defp settings_event("upload_logo", _params, socket) do
    admin = socket.assigns.current_user

    result =
      case uploaded_entries(socket, :logo) do
        {[_entry], []} ->
          [result] =
            consume_uploaded_entries(socket, :logo, fn %{path: path}, entry ->
              {:ok, Uploads.create(admin, path, entry.client_name, variant: "site")}
            end)

          result

        _none ->
          {:error, gettext("Pick an image.")}
      end

    with {:ok, upload} <- result,
         {:ok, _} <- SiteSettings.update(%{"logo_url" => Uploads.url(upload)}, admin) do
      {:noreply, socket |> put_flash(:info, gettext("Logo saved.")) |> load()}
    else
      {:error, message} when is_binary(message) -> {:noreply, put_flash(socket, :error, message)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("The logo couldn't be saved."))}
    end
  end

  defp settings_event("import", _params, socket) do
    text =
      consume_uploaded_entries(socket, :import, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    with [text] <- text,
         {:ok, settings} <- Transfer.parse(text),
         {:ok, %{changed: changed, skipped: skipped}} <-
           Transfer.import(settings, socket.assigns.current_user) do
      message =
        gettext("Imported %{changed} changed settings.", changed: length(changed)) <>
          if(skipped == [],
            do: "",
            else: " " <> gettext("Skipped: %{keys}.", keys: Enum.join(skipped, ", "))
          )

      {:noreply, socket |> put_flash(:info, message) |> load()}
    else
      [] ->
        {:noreply, put_flash(socket, :error, gettext("Pick a JSON or YAML file."))}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, errors} when is_map(errors) ->
        details = Enum.map_join(errors, "; ", fn {key, message} -> "#{key} #{message}" end)

        {:noreply,
         put_flash(socket, :error, gettext("Nothing was imported: %{details}", details: details))}
    end
  end

  # A secret's field is empty (it's never shown): left empty, it's kept.
  defp drop_blank_secrets(params) do
    secrets = for d <- SiteSettings.definitions(), d[:secret], do: d.key
    Map.reject(params, fn {key, value} -> key in secrets and String.trim(value) == "" end)
  end

  defp form_values(values) do
    secrets = for d <- SiteSettings.definitions(), d[:secret], do: d.key

    Map.new(values, fn {key, value} ->
      {key, if(key in secrets, do: "", else: display(value))}
    end)
  end

  defp display(value) when is_list(value), do: Enum.join(value, ", ")
  defp display(value), do: to_string(value)

  defp assign_form(socket, values, errors) do
    errors = Enum.map(errors, fn {key, message} -> {field(key), {message, []}} end)
    assign(socket, :form, to_form(values, as: :settings, errors: errors, action: :validate))
  end

  # Form fields are atoms; keys come from the definitions, never from input.
  defp field(key), do: String.to_atom(key)

  defp input_type(%{secret: true}), do: "password"
  defp input_type(%{type: :boolean}), do: "checkbox"
  defp input_type(%{type: :integer}), do: "number"
  defp input_type(%{type: :text}), do: "textarea"
  defp input_type(%{type: :email}), do: "email"
  defp input_type(%{type: :select}), do: "select"
  defp input_type(%{type: :color}), do: "color"
  defp input_type(%{type: _string_list_or_upload}), do: "text"

  defp default_text(%{secret: true}), do: nil
  defp default_text(%{default: value}) when value in ["", []], do: gettext("blank")
  defp default_text(%{default: true}), do: gettext("on")
  defp default_text(%{default: false}), do: gettext("off")
  defp default_text(%{default: value}), do: display(value)

  defp history_value(nil), do: gettext("blank")
  defp history_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp history_value(value), do: to_string(value)

  defp anchor(section), do: "settings-" <> String.replace(String.downcase(section), " ", "-")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title={gettext("Site settings")} navigate={~p"/staff/settings"}>
        <:subtitle>{gettext("Changes apply at once and are recorded in the staff log.")}</:subtitle>
        <:actions>
          <.link href={~p"/staff/settings/export/json"} class="btn btn-sm">{gettext("Export JSON")}</.link>
          <.link href={~p"/staff/settings/export/yaml"} class="btn btn-sm">{gettext("Export YAML")}</.link>
        </:actions>
      </.page_header>

      <form id="settings-filters" phx-change="filter" phx-submit="filter" class="space-y-3">
        <fieldset class="tabs tabs-box w-fit flex-wrap">
          <legend class="sr-only">{gettext("Category")}</legend>
          <label class={["tab", @filters["category"] == "" && "tab-active"]}>
            <input type="radio" name="category" value="" checked={@filters["category"] == ""} class="sr-only" />
            {gettext("All")}
          </label>
          <label :for={category <- @categories} class={["tab", @filters["category"] == category && "tab-active"]}>
            <input
              type="radio"
              name="category"
              value={category}
              checked={@filters["category"] == category}
              class="sr-only"
            />
            {category}
          </label>
        </fieldset>
        <div class="flex flex-wrap items-center gap-3">
          <label class="input grow">
            <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
            <input
              type="search"
              name="q"
              value={@filters["q"]}
              phx-debounce="200"
              placeholder={gettext("Search settings")}
              aria-label={gettext("Search settings")}
            />
          </label>
          <label class="label cursor-pointer gap-2">
            <input type="hidden" name="changed" value="" />
            <input type="checkbox" name="changed" value="1" checked={@filters["changed"] == "1"} class="toggle toggle-sm" />
            {gettext("Changed only")}
          </label>
        </div>
      </form>

      <p :if={@shown == []} id="no-settings" class="text-base-content/70">{gettext("No settings match.")}</p>

      <.form :if={@shown != []} for={@form} id="site-settings" phx-submit="save" class="space-y-6">
        <fieldset
          :for={[%{section: section, category: category} | _] = definitions <- @sections}
          id={anchor(section)}
          class="card border border-base-300 bg-base-100"
        >
          <div class="card-body gap-2">
            <legend class="card-title">{section}</legend>
            <p class="text-xs text-base-content/60">{category}</p>
            <div :if={section == "Logins"} id="login-methods" class="text-sm">
              <p class="text-base-content/70">
                {gettext("Login providers are configured in the server's environment (FIREFLY_* variables).")}
                {if Firefly.Accounts.Auth.sso_only?(), do: gettext("Single sign-on is the only way to log in.")}
              </p>
              <ul class="mt-1 flex flex-wrap gap-1">
                <li
                  :for={provider <- Firefly.Accounts.Auth.providers()}
                  class={["badge badge-sm", Firefly.Accounts.Auth.enabled?(provider) && "badge-success"]}
                >
                  {Firefly.Accounts.Auth.label(provider)}: {if Firefly.Accounts.Auth.enabled?(provider),
                    do: gettext("on"),
                    else: gettext("off")}
                </li>
              </ul>
            </div>
            <div
              :for={definition <- definitions}
              id={"setting-" <> definition.key}
              class="border-t border-base-200 pt-2 first-of-type:border-0"
            >
              <% pinned = SiteSettings.env_override(definition.key) %>
              <% customized = SiteSettings.customized?(definition.key) %>
              <.input
                field={@form[field(definition.key)]}
                type={input_type(definition)}
                label={definition.label}
                checked={definition.type == :boolean && @form.params[definition.key] == "true"}
                min={definition[:min]}
                max={definition[:max]}
                options={if definition.type == :select, do: definition[:options]}
                disabled={!!pinned}
                placeholder={if definition[:secret], do: gettext("Set: leave blank to keep it")}
              />
              <p class="-mt-1 text-xs text-base-content/70">{definition.help}</p>
              <div class="mt-1 flex flex-wrap items-center gap-2 text-xs">
                <span :if={default_text(definition)} class="text-base-content/60">
                  {gettext("Default: %{value}", value: default_text(definition))}
                </span>
                <span :if={customized} class="badge badge-xs badge-info">{gettext("changed")}</span>
                <span :if={pinned} id={"pinned-" <> definition.key} class="badge badge-xs badge-warning">
                  {gettext("Set by %{env}", env: pinned)}
                </span>
                <button
                  :if={customized and !pinned}
                  type="button"
                  phx-click="reset"
                  phx-value-key={definition.key}
                  data-confirm={gettext("Reset %{label} to its default?", label: definition.label)}
                  class="btn btn-ghost btn-xs"
                >
                  {gettext("Reset to default")}
                </button>
                <button
                  type="button"
                  phx-click="history"
                  phx-value-key={definition.key}
                  class="btn btn-ghost btn-xs"
                  aria-expanded={to_string(match?({_, _}, @history) and elem(@history, 0) == definition.key)}
                >
                  {gettext("History")}
                </button>
              </div>
              <ul
                :if={match?({_, _}, @history) and elem(@history, 0) == definition.key}
                id={"history-" <> definition.key}
                class="mt-1 space-y-1 text-xs"
              >
                <li :if={elem(@history, 1) == []} class="text-base-content/60">{gettext("Never changed.")}</li>
                <li :for={{change, index} <- Enum.with_index(elem(@history, 1))}>
                  <.time_ago id={"history-#{definition.key}-#{index}"} at={change.at} />
                  · {if change.actor, do: "@" <> change.actor.username, else: gettext("the system")}
                  · {history_value(change.before)} → {history_value(change.after)}
                  <span :if={change.reset} class="badge badge-xs">{gettext("reset")}</span>
                </li>
              </ul>
              <img
                :if={definition.type == :upload and @form.params[definition.key] not in [nil, ""]}
                src={@form.params[definition.key]}
                alt={gettext("Current %{label}", label: definition.label)}
                class="mt-2 h-12 w-auto rounded border border-base-300"
              />
            </div>
          </div>
        </fieldset>
        <div class="flex justify-end">
          <.button variant="primary" phx-disable-with={gettext("Saving...")}>{gettext("Save settings")}</.button>
        </div>
      </.form>

      <section :if={Enum.any?(@shown, &(&1.key == "logo_url"))} id="logo-upload" class="card border border-base-300 bg-base-100">
        <form id="logo-form" phx-submit="upload_logo" phx-change="validate_upload" class="card-body gap-2">
          <h2 class="card-title">{gettext("Upload a logo")}</h2>
          <.live_file_input upload={@uploads.logo} class="file-input" aria-label={gettext("Logo image")} />
          <div><.button variant="primary">{gettext("Use as logo")}</.button></div>
        </form>
      </section>

      <section id="settings-import" class="card border border-base-300 bg-base-100">
        <form id="import-form" phx-submit="import" phx-change="validate_upload" class="card-body gap-2">
          <h2 class="card-title">{gettext("Import settings")}</h2>
          <p class="text-sm text-base-content/70">
            {gettext("A JSON or YAML export (of this site or another). Every value is checked first, and each change is logged. Secrets and settings pinned by the environment are skipped.")}
          </p>
          <.live_file_input upload={@uploads.import} class="file-input" aria-label={gettext("Settings file")} />
          <div><.button variant="primary">{gettext("Import")}</.button></div>
        </form>
      </section>
    </Layouts.app>
    """
  end
end
