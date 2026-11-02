defmodule FireflyWeb.AuthLive.MagicLink do
  @moduledoc """
  Asks for a login link by email (see `Firefly.MagicLinks`). The
  answer is the same whether or not an account has the address.
  """
  use FireflyWeb, :live_view

  alias Firefly.{MagicLinks, RateLimit}

  @impl true
  def mount(_params, _session, socket) do
    if MagicLinks.enabled?() do
      {:ok,
       socket
       |> assign(:page_title, "Log in by email")
       |> assign(:remote_ip, FireflyWeb.ClientIP.from_socket(socket))
       |> assign(:form, to_form(%{"email" => ""}, as: :login))}
    else
      {:ok, socket |> put_flash(:error, "Email login links are off.") |> redirect(to: ~p"/login")}
    end
  end

  @impl true
  def handle_event("send", %{"login" => %{"email" => email}}, socket) do
    case MagicLinks.deliver(email, socket.assigns.remote_ip) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "If that address can log in here, we've emailed it a link. It works once, for 15 minutes."
         )
         |> push_navigate(to: ~p"/login")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, RateLimit.message())}

      {:error, _disabled} ->
        {:noreply, put_flash(socket, :error, "Email login links are off.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-4 py-8">
        <.page_header title="Log in by email">
          <:subtitle>We'll email you a link that logs you in.</:subtitle>
        </.page_header>
        <.form for={@form} id="magic-link-form" phx-submit="send" class="space-y-2">
          <.input field={@form[:email]} type="email" label="Email" autocomplete="email" />
          <.button variant="primary" class="btn btn-primary w-full" phx-disable-with="Sending...">
            Email me a link
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
