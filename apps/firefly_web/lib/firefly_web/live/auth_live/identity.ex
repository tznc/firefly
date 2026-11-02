defmodule FireflyWeb.AuthLive.Identity do
  @moduledoc """
  Username and password login. On submit the form posts to the Ueberauth
  identity callback, which writes the session. New accounts register at
  `/register`. Passkeys work here too, also through the browser's autofill
  on the username field (see `AuthLive.Login.passkey_form/1`).
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :password_login})

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Log In")
     |> assign(:trigger_submit, false)
     |> assign(:passkeys, Firefly.Passkeys.enabled?())
     |> assign(:magic_links, Firefly.MagicLinks.enabled?())
     |> assign(:form, to_form(%{"username" => "", "password" => ""}, as: :user))}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :user))}
  end

  def handle_event("submit", %{"user" => params}, socket) do
    errors =
      for field <- ~w(username password), blank?(params[field]) do
        {String.to_existing_atom(field), {"can't be blank", [validation: :required]}}
      end

    if errors == [] do
      {:noreply, assign(socket, form: to_form(params, as: :user), trigger_submit: true)}
    else
      {:noreply,
       assign(socket, :form, to_form(params, as: :user, errors: errors, action: :validate))}
    end
  end

  defp blank?(value), do: is_nil(value) or String.trim(value) == ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-4 py-8">
        <.page_header title="Log In">
          <:subtitle :if={Firefly.Forums.registration_open?()}>
            New here? <.link navigate={~p"/register"} class="link">Create an account</.link>
          </:subtitle>
        </.page_header>
        <.form
          for={@form}
          id="identity-form"
          action={~p"/auth/identity/callback"}
          method="post"
          phx-change="validate"
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
          class="space-y-2"
        >
          <.input
            field={@form[:username]}
            type="text"
            label="Username"
            autocomplete={if @passkeys, do: "username webauthn", else: "username"}
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
          />
          <.button variant="primary" class="btn btn-primary w-full">Log in</.button>
          <p class="text-center text-sm">
            <.link navigate={~p"/reset-password"} class="link">Forgot your password?</.link>
            <span :if={@magic_links}>
              · <.link navigate={~p"/login/email"} class="link">Email me a login link</.link>
            </span>
          </p>
        </.form>
        <div :if={@passkeys} class="divider text-xs">or</div>
        <FireflyWeb.AuthLive.Login.passkey_form :if={@passkeys} conditional />
      </section>
    </Layouts.app>
    """
  end
end
