defmodule FireflyWeb.AuthLive.ResetPassword do
  @moduledoc "Sets a new password from an emailed reset link."
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :password_login})

  alias Firefly.Accounts
  alias Firefly.Accounts.{PasswordReset, User}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case PasswordReset.verify(token) do
      {:ok, user} ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Choose a new password"))
         |> assign(:user, user)
         |> assign(:form, to_form(User.password_changeset(user, %{}), as: :user))}

      {:error, _} ->
        # Once per visit: the first, static render runs in the request.
        if not connected?(socket), do: Firefly.Security.Jail.signal_client("invalid_token")

        {:ok,
         socket
         |> put_flash(:error, gettext("That reset link is invalid or has expired."))
         |> push_navigate(to: ~p"/reset-password")}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = User.password_changeset(socket.assigns.user, params)
    {:noreply, assign(socket, :form, to_form(changeset, as: :user, action: :validate))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.reset_user_password(socket.assigns.user, params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Password reset. Log in with your new password."))
         |> push_navigate(to: ~p"/auth/identity")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-4 py-8">
        <.page_header title={gettext("Choose a new password")}>
          <:subtitle>For {@user.username}</:subtitle>
        </.page_header>
        <.form
          for={@form}
          id="reset-password-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-2"
        >
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("New password")}
            autocomplete="new-password"
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label={gettext("Confirm new password")}
            autocomplete="new-password"
          />
          <.button variant="primary" class="btn btn-primary w-full" phx-disable-with={gettext("Saving...")}>
            {gettext("Reset password")}
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
