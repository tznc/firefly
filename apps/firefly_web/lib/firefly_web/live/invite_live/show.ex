defmodule FireflyWeb.InviteLive.Show do
  @moduledoc """
  An invitation's page (see `Firefly.Accounts.Invites`): visitors create
  their account here, with a password or a social or single sign-on login
  (through `FireflyWeb.InviteController`); signed-in members accept it to
  join its group. Either way they then go where the invite says.
  """
  use FireflyWeb, :live_view

  alias Firefly.{Accounts, RateLimit}
  alias Firefly.Accounts.{Auth, EmailConfirmation, Invite, Invites, User}

  @impl true
  def mount(%{"key" => key}, _session, socket) do
    case Invites.get_by_key(key) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That invitation doesn't exist.")
         |> push_navigate(to: ~p"/")}

      invite ->
        {:ok,
         socket
         |> assign(:page_title, "Invitation")
         |> assign(:invite, invite)
         |> assign(:problem, problem(invite))
         |> assign(:providers, Auth.enabled_providers())
         |> assign(:password_login, Auth.password_login?())
         |> assign(:remote_ip, FireflyWeb.ClientIP.from_socket(socket))
         |> assign(:trigger_submit, false)
         |> assign_form(Accounts.change_registration(%User{}, %{"email" => invite.email}))}
    end
  end

  defp problem(invite) do
    case Invite.problem(invite) || Invites.open() do
      :ok -> nil
      {:error, reason} -> Invites.message(reason)
      reason -> Invites.message(reason)
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = Accounts.change_registration(%User{}, fixed_email(params, socket))
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    params = fixed_email(params, socket)

    with :ok <- RateLimit.check_register(socket.assigns.remote_ip),
         {:ok, user} <- Invites.register(socket.assigns.invite, params) do
      unless User.confirmed?(user), do: EmailConfirmation.deliver(user)

      # The form posts the same values to the login callback.
      {:noreply,
       socket
       |> assign(:trigger_submit, true)
       |> assign(:form, to_form(params, as: :user))}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:noreply, assign_form(socket, changeset)}
      {:error, :rate_limited} -> {:noreply, put_flash(socket, :error, RateLimit.message())}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Invites.message(reason))}
    end
  end

  def handle_event("accept", _params, %{assigns: %{current_user: %User{} = user}} = socket) do
    case Invites.redeem(socket.assigns.invite, user) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation accepted.")
         |> push_navigate(to: Invites.destination(Firefly.Repo.preload(invite, :thread)))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Invites.message(reason))}
    end
  end

  # An email invite is for its address.
  defp fixed_email(params, %{assigns: %{invite: %Invite{email: email}}}) when is_binary(email),
    do: Map.put(params, "email", email)

  defp fixed_email(params, _socket), do: params

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset, as: :user))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-4 py-8">
        <.page_header title={"Join #{Firefly.SiteSettings.get("title")}"}>
          <:subtitle>@{@invite.invited_by.username} invited you.</:subtitle>
        </.page_header>

        <p :if={@problem} id="invite-problem" class="alert alert-warning">{@problem}</p>

        <div :if={!@problem && @current_user} id="invite-accept" class="space-y-2">
          <p>You're signed in as @{@current_user.username}.</p>
          <.button phx-click="accept" variant="primary" class="w-full">Accept invitation</.button>
        </div>

        <div :if={!@problem && !@current_user} class="space-y-4">
          <a
            :for={provider <- @providers}
            href={~p"/invites/#{@invite.key}/login/#{provider}"}
            id={"invite-login-#{provider}"}
            class="btn btn-neutral w-full"
          >
            Sign up with {Auth.label(provider)}
          </a>
          <div :if={@providers != [] and @password_login} class="divider text-xs">or</div>
          <.form
            :if={@password_login}
            for={@form}
            id="invite-registration-form"
            action={~p"/auth/identity/callback"}
            method="post"
            phx-change="validate"
            phx-submit="save"
            phx-trigger-action={@trigger_submit}
            class="space-y-2"
          >
            <input type="hidden" name="return_to" value={Invites.destination(@invite)} />
            <.input field={@form[:username]} type="text" label="Username" autocomplete="username" />
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              readonly={Invite.email?(@invite)}
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="new-password"
              value={@form[:password].value}
            />
            <FireflyWeb.PasswordComponents.strength_meter
              id="password-strength"
              password={@form[:password].value}
              words={[@form[:username].value, @form[:email].value]}
            />
            <.button variant="primary" class="btn btn-primary w-full" phx-disable-with="Creating...">
              Create account
            </.button>
          </.form>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
