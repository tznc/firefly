defmodule FireflyWeb.AuthLive.Identity do
  @moduledoc """
  Username and password login. On submit the form posts to the Ueberauth
  identity callback, which writes the session. New accounts register at
  `/register`. Passkeys work here too, also through the browser's autofill
  on the username field (see `AuthLive.Login.passkey_form/1`).

  After repeated failures a login needs the bot challenge (see
  `Firefly.Security.Challenge.required_for_login?/2`): the form shows it
  when the address needs it, when the callback asked for it
  (`?challenge=1`), or when the username needs it on submit. The callback
  checks the answer (`FireflyWeb.BotChallenge.check_login/2`).
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :password_login})

  alias Firefly.Security.Challenge
  alias FireflyWeb.BotChallenge

  @impl true
  def mount(params, _session, socket) do
    remote_ip = FireflyWeb.ClientIP.from_socket(socket)

    {:ok,
     socket
     |> assign(:page_title, gettext("Log in"))
     |> assign(:remote_ip, remote_ip)
     |> challenge(params["challenge"] == "1" or Challenge.required_for_login?(nil, remote_ip))
     |> assign(:trigger_submit, false)
     |> assign(:passkeys, Firefly.Accounts.Passkeys.enabled?())
     |> assign(:magic_links, Firefly.Accounts.MagicLinks.enabled?())
     |> assign(
       :form,
       to_form(%{"username" => "", "password" => "", "remember_me" => "true"}, as: :user)
     )}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :user))}
  end

  def handle_event("submit", %{"user" => params} = form, socket) do
    errors =
      for field <- ~w(username password), blank?(params[field]) do
        {String.to_existing_atom(field), {"can't be blank", [validation: :required]}}
      end

    socket = assign(socket, :form, to_form(params, as: :user))

    cond do
      errors != [] ->
        {:noreply,
         assign(socket, :form, to_form(params, as: :user, errors: errors, action: :validate))}

      is_nil(socket.assigns.bot_challenge) and
          Challenge.required_for_login?(params["username"], socket.assigns.remote_ip) ->
        {:noreply, socket |> challenge(true) |> put_flash(:error, BotChallenge.wait_message())}

      socket.assigns.bot_challenge && blank?(form["bot_challenge"]) ->
        {:noreply, put_flash(socket, :error, BotChallenge.wait_message())}

      true ->
        {:noreply, assign(socket, :trigger_submit, true)}
    end
  end

  defp blank?(value), do: is_nil(value) or String.trim(value) == ""

  defp challenge(socket, true), do: BotChallenge.assign_challenge(socket)

  defp challenge(socket, false),
    do: assign(socket, bot_challenge: nil, bot_challenge_id: "bot-challenge")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-4 py-8">
        <.page_header title={gettext("Log in")}>
          <:subtitle :if={Firefly.Accounts.registration_open?()}>
            {gettext("New here?")}
            <.link navigate={~p"/register"} class="link">{gettext("Create an account")}</.link>
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
            label={gettext("Username")}
            autocomplete={if @passkeys, do: "username webauthn", else: "username"}
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="current-password"
          />
          <.input
            field={@form[:remember_me]}
            type="checkbox"
            label={gettext("Keep me logged in")}
          />
          <BotChallenge.bot_challenge id={@bot_challenge_id} widget={@bot_challenge} />
          <.button variant="primary" class="btn btn-primary w-full">{gettext("Log in")}</.button>
          <p class="text-center text-sm">
            <.link navigate={~p"/reset-password"} class="link">{gettext("Forgot your password?")}</.link>
            <span :if={@magic_links}>
              · <.link navigate={~p"/login/email"} class="link">{gettext("Email me a login link")}</.link>
            </span>
          </p>
        </.form>
        <div :if={@passkeys} class="divider text-xs">{gettext("or")}</div>
        <FireflyWeb.AuthLive.Login.passkey_form :if={@passkeys} conditional />
      </section>
    </Layouts.app>
    """
  end
end
