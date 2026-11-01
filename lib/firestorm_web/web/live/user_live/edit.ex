defmodule FirestormWeb.Web.UserLive.Edit do
  @moduledoc "Edits the current user's own profile."
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.User

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = Forums.get_user!(id)

    case Bodyguard.permit(Forums, :edit_user, socket.assigns.current_user, user: user) do
      :ok ->
        {:ok,
         socket
         |> assign(:page_title, "Edit profile")
         |> assign(:user, user)
         |> assign(:form, to_form(Forums.change_user(user)))}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "You can only edit your own profile.")
         |> push_navigate(to: ~p"/users/#{user}")}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = User.changeset(socket.assigns.user, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    # Only the fields on the form; never e.g. the API token.
    params = Map.take(params, ~w(username name email))

    case Forums.update_user(socket.assigns.user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User updated successfully.")
         |> push_navigate(to: ~p"/users/#{user}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Edit profile" />

      <.form for={@form} id="user-form" phx-change="validate" phx-submit="save" class="space-y-2">
        <.input field={@form[:username]} type="text" label="Username" />
        <p class="-mt-1 text-xs text-base-content/60">People can mention you as @username</p>
        <.input field={@form[:name]} type="text" label="Name" />
        <p class="-mt-1 text-xs text-base-content/60">Your full name (optional)</p>
        <.input field={@form[:email]} type="email" label="Email" />
        <p class="-mt-1 text-xs text-base-content/60">Never shown to the public</p>
        <div class="flex items-center gap-3 py-2">
          <.avatar user={@user} size="size-14" />
          <p class="text-sm text-base-content/70">
            Your avatar is set at <a href="https://gravatar.com" class="link">gravatar.com</a>
          </p>
        </div>
        <div class="flex justify-end gap-2">
          <.link navigate={~p"/users/#{@user}"} class="btn btn-ghost">Cancel</.link>
          <.button variant="primary" phx-disable-with="Saving...">Save</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
