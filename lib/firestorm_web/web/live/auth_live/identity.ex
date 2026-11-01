defmodule FirestormWeb.Web.AuthLive.Identity do
  @moduledoc """
  Username and password login. On submit the form posts to the Ueberauth
  identity callback, which writes the session. New accounts register at
  `/register`.
  """
  use FirestormWeb.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Log In")
     |> assign(:trigger_submit, false)
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
          <:subtitle>
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
          <.input field={@form[:username]} type="text" label="Username" autocomplete="username" />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
          />
          <.button variant="primary" class="btn btn-primary w-full">Log in</.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
