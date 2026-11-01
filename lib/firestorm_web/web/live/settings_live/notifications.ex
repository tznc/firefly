defmodule FirestormWeb.Web.SettingsLive.Notifications do
  @moduledoc "The current user's notification settings."
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.User

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Notification settings")
     |> assign(:form, to_form(User.preferences_changeset(user, %{}), as: :preferences))}
  end

  @impl true
  def handle_event("save", %{"preferences" => params}, socket) do
    case Forums.update_preferences(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:form, to_form(User.preferences_changeset(user, %{}), as: :preferences))
         |> put_flash(:info, "Notification settings saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :preferences))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Notification settings" />

      <.form for={@form} id="preferences-form" phx-submit="save" class="space-y-4">
        <.input
          field={@form[:email_notifications]}
          type="checkbox"
          label="Email me about new posts in threads and categories I'm watching"
        />
        <.button variant="primary" phx-disable-with="Saving...">Save</.button>
      </.form>

      <div class="prose prose-sm max-w-none text-base-content/80">
        <h2 class="text-base">Notification levels</h2>
        <p>Set a level from the menu on any thread or category:</p>
        <ul>
          <li>
            <strong>Watching</strong>: notified of every new post, and emailed (once per thread until you've read it).
          </li>
          <li><strong>Tracking</strong>: notified of every new post, no email.</li>
          <li><strong>Normal</strong>: not notified.</li>
          <li><strong>Muted</strong>: not notified, and hidden from Latest, New and Unread.</li>
        </ul>
        <p>
          Threads you start are watched; threads you reply to are tracked. A category's level applies to its threads unless you set one on the thread.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
