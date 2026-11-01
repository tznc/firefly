defmodule FirestormWeb.Web.AuthLive.Registration do
  @moduledoc """
  Account registration with a username, email and password. The account is
  created here; the form then posts to the identity callback to log in, which
  writes the session.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{EmailConfirmation, Forums, RateLimit}

  @impl true
  def mount(_params, _session, socket) do
    remote_ip =
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _ -> nil
      end

    {:ok,
     socket
     |> assign(:page_title, "Create an account")
     |> assign(:remote_ip, remote_ip)
     |> assign(:trigger_submit, false)
     |> assign_form(Forums.change_registration())}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = Forums.change_registration(%Forums.User{}, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # Bots fill in every field; people never see this one.
  def handle_event("save", %{"user" => %{"website" => website}}, socket)
      when website != "" do
    {:noreply, put_flash(socket, :error, "Registration failed. Please try again.")}
  end

  def handle_event("save", %{"user" => params}, socket) do
    with :ok <- RateLimit.check_register(socket.assigns.remote_ip || "unknown"),
         {:ok, user} <- Forums.register_user(params) do
      EmailConfirmation.deliver(user)

      # Keep the submitted values so the form can post them to the login callback.
      {:noreply,
       socket
       |> assign(:trigger_submit, true)
       |> assign(:form, to_form(params, as: :user))}
    else
      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, RateLimit.message())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :user))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-4 py-8">
        <.page_header title="Create an account">
          <:subtitle>
            Already have one? <.link navigate={~p"/auth/identity"} class="link">Log in</.link>
          </:subtitle>
        </.page_header>
        <.form
          for={@form}
          id="registration-form"
          action={~p"/auth/identity/callback"}
          method="post"
          phx-change="validate"
          phx-submit="save"
          phx-trigger-action={@trigger_submit}
          class="space-y-2"
        >
          <.input field={@form[:username]} type="text" label="Username" autocomplete="username" />
          <.input field={@form[:email]} type="email" label="Email" autocomplete="email" />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            value={@form[:password].value}
          />
          <div class="hidden" aria-hidden="true">
            <label for="user_website">Website</label>
            <input type="text" id="user_website" name="user[website]" tabindex="-1" autocomplete="off" />
          </div>
          <.button variant="primary" class="btn btn-primary w-full" phx-disable-with="Creating...">
            Create account
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
