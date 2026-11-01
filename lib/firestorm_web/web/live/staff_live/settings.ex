defmodule FirestormWeb.Web.StaffLive.Settings do
  @moduledoc """
  Site settings (admins only), grouped into sections. Saving validates every
  value for its type and saves the ones that changed; see
  `FirestormWeb.SiteSettings`.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.SiteSettings

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_site_settings) do
      {:ok,
       socket
       |> assign(:page_title, "Site settings")
       |> assign(:sections, Enum.chunk_by(SiteSettings.definitions(), & &1.section))
       |> assign_form(form_values(SiteSettings.all()), %{})}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save", %{"settings" => params}, socket) do
    case SiteSettings.update(params, socket.assigns.current_user) do
      {:ok, changes} ->
        message =
          if changes == %{},
            do: "Nothing changed.",
            else: "Settings saved: #{Enum.join(Map.keys(changes), ", ")}."

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign_form(form_values(SiteSettings.all()), %{})}

      {:error, errors} ->
        {:noreply,
         socket
         |> put_flash(:error, "Some settings are invalid; nothing was saved.")
         |> assign_form(params, errors)}
    end
  end

  defp form_values(values), do: Map.new(values, fn {key, value} -> {key, to_string(value)} end)

  defp assign_form(socket, values, errors) do
    errors = Enum.map(errors, fn {key, message} -> {field(key), {message, []}} end)
    assign(socket, :form, to_form(values, as: :settings, errors: errors, action: :validate))
  end

  # Form fields are atoms; keys come from the definitions, never from input.
  defp field(key), do: String.to_atom(key)

  defp input_type(:boolean), do: "checkbox"
  defp input_type(:integer), do: "number"
  defp input_type(:text), do: "textarea"
  defp input_type(:email), do: "email"
  defp input_type(:string), do: "text"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Site settings" navigate={~p"/staff/settings"}>
        <:subtitle>Changes apply at once and are recorded in the staff log.</:subtitle>
      </.page_header>

      <.form for={@form} id="site-settings" phx-submit="save" class="space-y-6">
        <fieldset
          :for={[%{section: section} | _] = definitions <- @sections}
          id={"settings-" <> String.replace(String.downcase(section), " ", "-")}
          class="card border border-base-300 bg-base-100"
        >
          <div class="card-body gap-2">
            <legend class="card-title">{section}</legend>
            <div :for={definition <- definitions}>
              <.input
                field={@form[field(definition.key)]}
                type={input_type(definition.type)}
                label={definition.label}
                checked={definition.type == :boolean && @form.params[definition.key] == "true"}
                min={definition[:min]}
                max={definition[:max]}
              />
              <p class="-mt-1 text-xs text-base-content/60">{definition.help}</p>
            </div>
          </div>
        </fieldset>
        <div class="flex justify-end">
          <.button variant="primary" phx-disable-with="Saving...">Save settings</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
