defmodule FireflyWeb.AuthLive.Registration do
  @moduledoc """
  Account registration with a username, email and password. The account is
  created here; the form then posts to the identity callback to log in, which
  writes the session. Closed while the `allow_registrations` site setting is
  off. New accounts are always sent a confirmation link; with
  `require_email_confirmation` off they can post before following it.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :password_login})

  alias Firefly.{Accounts, RateLimit}
  alias Firefly.Accounts.EmailConfirmation

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.registration_open?(),
      do: mount_form(socket),
      else: {:ok, closed(socket)}
  end

  defp closed(socket) do
    socket
    |> put_flash(:error, gettext("New registrations are closed."))
    |> push_navigate(to: ~p"/login")
  end

  defp mount_form(socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Create an account"))
     |> assign(:remote_ip, FireflyWeb.ClientIP.from_socket(socket))
     |> assign(:trigger_submit, false)
     |> assign_form(Accounts.change_registration())}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = Accounts.change_registration(%Firefly.Accounts.User{}, params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # Bots fill in every field; people never see this one.
  def handle_event("save", %{"user" => %{"website" => website}}, socket)
      when website != "" do
    {:noreply, put_flash(socket, :error, gettext("Registration failed. Please try again."))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    with :ok <- RateLimit.check_register(socket.assigns.remote_ip),
         {:ok, user} <- Accounts.register_user(params) do
      unless Firefly.Accounts.User.confirmed?(user), do: EmailConfirmation.deliver(user)

      # Keep the submitted values so the form can post them to the login callback.
      {:noreply,
       socket
       |> assign(:trigger_submit, true)
       |> assign(:form, to_form(params, as: :user))}
    else
      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, RateLimit.message())}

      {:error, :registration_closed} ->
        {:noreply, closed(socket)}

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
        <.page_header title={gettext("Create an account")}>
          <:subtitle>
            {gettext("Already have one?")}
            <.link navigate={~p"/auth/identity"} class="link">{gettext("Log in")}</.link>
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
          <.input field={@form[:username]} type="text" label={gettext("Username")} autocomplete="username" />
          <.input field={@form[:email]} type="email" label={gettext("Email")} autocomplete="email" />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="new-password"
            value={@form[:password].value}
          />
          <div class="hidden" aria-hidden="true">
            <label for="user_website">{gettext("Website")}</label>
            <input type="text" id="user_website" name="user[website]" tabindex="-1" autocomplete="off" />
          </div>
          <.button variant="primary" class="btn btn-primary w-full" phx-disable-with={gettext("Creating...")}>
            {gettext("Create account")}
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
