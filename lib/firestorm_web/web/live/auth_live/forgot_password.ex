defmodule FirestormWeb.Web.AuthLive.ForgotPassword do
  @moduledoc "Requests a password reset link by email."
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{PasswordReset, RateLimit}

  @sent "If an account with a password uses that email, we've sent it a link to reset the password."

  @impl true
  def mount(_params, _session, socket) do
    remote_ip =
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _ -> "unknown"
      end

    {:ok,
     socket
     |> assign(:page_title, "Reset your password")
     |> assign(:remote_ip, remote_ip)
     |> assign(:form, to_form(%{"email" => ""}, as: :user))}
  end

  @impl true
  def handle_event("send", %{"user" => %{"email" => email}}, socket) do
    case RateLimit.check_password_reset(socket.assigns.remote_ip) do
      :ok ->
        if String.contains?(email, "@"), do: PasswordReset.deliver_instructions(email)

        {:noreply,
         socket
         |> put_flash(:info, @sent)
         |> push_navigate(to: ~p"/auth/identity")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, RateLimit.message())}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-4 py-8">
        <.page_header title="Reset your password">
          <:subtitle>We'll email you a link to choose a new one.</:subtitle>
        </.page_header>
        <.form for={@form} id="forgot-password-form" phx-submit="send" class="space-y-2">
          <.input field={@form[:email]} type="email" label="Email" autocomplete="email" required />
          <.button variant="primary" class="btn btn-primary w-full" phx-disable-with="Sending...">
            Send reset link
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
