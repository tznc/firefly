defmodule FirestormWeb.Web.AuthLive.TwoFactor do
  @moduledoc """
  The second step of logging in with two-factor authentication: an
  authenticator or backup code, or a security key (the `SecurityKeyLogin`
  hook asks the browser for it with the challenge kept in the session).
  Both forms post to `FirestormWeb.Web.TwoFactorController`. Without a
  login waiting (or after 10 minutes), it's back to the login page.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{TwoFactor, WebAuthn}
  alias FirestormWeb.Web.Login

  @impl true
  def mount(_params, session, socket) do
    case Login.pending_user(session) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Your login timed out. Log in again.")
         |> redirect(to: ~p"/login")}

      user ->
        {:ok,
         socket
         |> assign(:page_title, "Two-factor authentication")
         |> assign(:totp?, TwoFactor.totp?(user))
         |> assign(:key_options, key_options(session, TwoFactor.credentials(user)))}
    end
  end

  defp key_options(_session, []), do: nil

  defp key_options(session, credentials) do
    case WebAuthn.from_session(session["two_factor_challenge"], credentials) do
      nil -> nil
      challenge -> Jason.encode!(WebAuthn.request_options(challenge, credentials))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-4 py-8">
        <.page_header title="Two-factor authentication">
          <:subtitle>One more step to log in.</:subtitle>
        </.page_header>
        <.form
          :if={@key_options}
          for={%{}}
          as={:key}
          id="security-key-form"
          action={~p"/login/two-factor/key"}
          method="post"
        >
          <input
            :for={field <- ~w(id authenticator_data signature client_data_json)}
            type="hidden"
            name={"key[#{field}]"}
            data-field={field}
          />
          <button
            type="button"
            id="use-security-key"
            phx-hook="SecurityKeyLogin"
            data-options={@key_options}
            class="btn btn-primary w-full"
          >
            <.icon name="hero-key" class="size-5" /> Use a security key
          </button>
        </.form>
        <div :if={@key_options} class="divider text-xs">or</div>
        <.form for={%{}} as={:two_factor} id="two-factor-form" action={~p"/login/two-factor"} method="post" class="space-y-2">
          <.input
            name="code"
            value=""
            type="text"
            label={if @totp?, do: "Authenticator or backup code", else: "Backup code"}
            autocomplete="one-time-code"
            inputmode={@totp? && "numeric"}
            autofocus
          />
          <.button variant="primary" class="btn btn-primary w-full">Verify</.button>
        </.form>
        <p class="text-center text-xs text-base-content/60">
          Lost your second factor? Use a backup code, or ask the staff to reset it.
        </p>
      </section>
    </Layouts.app>
    """
  end
end
