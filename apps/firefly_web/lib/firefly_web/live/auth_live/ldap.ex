defmodule FireflyWeb.AuthLive.LDAP do
  @moduledoc """
  Logging in with a directory username and password (see
  `Firefly.Accounts.Auth.LDAP`). On submit the form posts to
  `FireflyWeb.LDAPController`, which writes the session; for someone logged
  in already, it connects the directory account instead (from the
  settings' Logins tab).
  """
  use FireflyWeb, :live_view

  alias Firefly.Accounts.Auth.LDAP

  @impl true
  def mount(_params, _session, socket) do
    if LDAP.enabled?() do
      {:ok,
       socket
       |> assign(:page_title, "Log in with #{LDAP.label()}")
       |> assign(:label, LDAP.label())
       |> assign(:trigger_submit, false)
       |> assign(:form, to_form(%{"username" => "", "password" => ""}, as: :ldap))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Directory login isn't enabled.")
       |> redirect(to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("validate", %{"ldap" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :ldap))}
  end

  def handle_event("submit", %{"ldap" => params}, socket) do
    errors =
      for field <- ~w(username password), blank?(params[field]) do
        {String.to_existing_atom(field), {"can't be blank", [validation: :required]}}
      end

    if errors == [] do
      {:noreply, assign(socket, form: to_form(params, as: :ldap), trigger_submit: true)}
    else
      {:noreply,
       assign(socket, :form, to_form(params, as: :ldap, errors: errors, action: :validate))}
    end
  end

  defp blank?(value), do: is_nil(value) or String.trim(value) == ""

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-4 py-8">
        <.page_header title={"Log in with #{@label}"}>
          <:subtitle>Your {@label} username and password.</:subtitle>
        </.page_header>
        <.form
          for={@form}
          id="ldap-form"
          action={~p"/login/ldap"}
          method="post"
          phx-change="validate"
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
          class="space-y-2"
        >
          <.input field={@form[:username]} type="text" label="Username" autocomplete="username" />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
          />
          <.button variant="primary" class="btn btn-primary w-full">Log in</.button>
        </.form>
        <p class="text-center text-sm">
          <.link navigate={~p"/login"} class="link">Other ways to log in</.link>
        </p>
      </section>
    </Layouts.app>
    """
  end
end
