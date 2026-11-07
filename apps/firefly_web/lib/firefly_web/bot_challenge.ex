defmodule FireflyWeb.BotChallenge do
  @moduledoc """
  The bot challenge (see `Firefly.Security.Challenge`) in the sign-up,
  password reset, login link and login forms.

  `bot_challenge/1` goes in the form: the `BotChallenge` hook answers the
  challenge in the background (the proof of work, or the Turnstile or
  hCaptcha widget) and puts the answer in the form's `bot_challenge` field.
  There's no puzzle; a polite live region says what's happening, for screen
  readers too.

  A LiveView calls `assign_challenge/1` on mount and `check/2` on submit; an
  answer is good for one submission, so the page then gets a new challenge.
  The registration forms then post to the login callback with a
  `registered` token (`registered_token/1`) in place of a second answer.
  """
  use Phoenix.Component
  use Gettext, backend: FireflyWeb.Gettext

  alias Firefly.Accounts
  alias Firefly.Accounts.User
  alias Firefly.Security.Challenge

  @registered_max_age 5 * 60

  @doc "A new challenge for the page: the `:bot_challenge` and `:bot_challenge_id` assigns."
  def assign_challenge(socket) do
    socket
    |> assign(:bot_challenge, Challenge.widget())
    |> assign(:bot_challenge_id, "bot-challenge-#{System.unique_integer([:positive])}")
  end

  @doc """
  Checks a submitted form's answer: `{:ok, socket}`, or `{:error, socket}`
  with an error flash. Either way but a blank answer (the check hasn't
  finished yet), the socket gets a new challenge.
  """
  def check(socket, params) do
    answer = params["bot_challenge"]

    cond do
      is_nil(socket.assigns.bot_challenge) ->
        {:ok, socket}

      answer in [nil, ""] ->
        {:error, Phoenix.LiveView.put_flash(socket, :error, wait_message())}

      true ->
        case Challenge.verify(answer, socket.assigns.remote_ip) do
          :ok ->
            {:ok, assign_challenge(socket)}

          {:error, :bot_challenge} ->
            {:error,
             socket |> assign_challenge() |> Phoenix.LiveView.put_flash(:error, failed_message())}
        end
    end
  end

  @doc "Asked to wait for the check."
  def wait_message,
    do: gettext("Wait a moment for the check that you're not a bot, then try again.")

  @doc "The check failed."
  def failed_message,
    do: gettext("The check that you're not a bot didn't pass. Please try again.")

  @doc """
  Checks a password login's answer (`params` of the login callback, from
  `ip`) when the login needs one (`Challenge.required_for_login?/2`), or
  the `registered` token of an account just created on this site's forms.
  """
  def check_login(params, ip) do
    username = get_in(params, ["user", "username"])

    cond do
      registered?(params["registered"], username) -> :ok
      Challenge.required_for_login?(username, ip) -> Challenge.verify(params["bot_challenge"], ip)
      true -> :ok
    end
  end

  @doc "Lets the new `user` log in without a second challenge, for a few minutes."
  def registered_token(%User{id: id}),
    do: Phoenix.Token.sign(FireflyWeb.Endpoint, "registered", id)

  defp registered?(token, username) when is_binary(token) and is_binary(username) do
    with {:ok, id} <-
           Phoenix.Token.verify(FireflyWeb.Endpoint, "registered", token,
             max_age: @registered_max_age
           ),
         %User{id: ^id} <- Accounts.get_user_by_username(username) do
      true
    else
      _ -> false
    end
  end

  defp registered?(_token, _username), do: false

  attr :id, :string, required: true, doc: "a new id gets a new challenge (after a used one)"
  attr :widget, :map, required: true, doc: "`Firefly.Security.Challenge.widget/0`, or nil"

  @doc "The challenge's field and status, inside a form."
  def bot_challenge(assigns) do
    ~H"""
    <div
      :if={@widget}
      id={@id}
      phx-hook="BotChallenge"
      phx-update="ignore"
      class="space-y-1"
      data-mode={@widget.mode}
      data-challenge={@widget[:challenge]}
      data-site-key={@widget[:site_key]}
      data-script={@widget[:script]}
      data-done={gettext("Checked: you can go on.")}
      data-failed={gettext("The check didn't work. Reload the page to try again.")}
    >
      <input type="hidden" name="bot_challenge" value="" />
      <div data-provider></div>
      <p class="text-sm text-base-content/70" role="status" aria-live="polite" data-status>
        {gettext("Checking that you're not a bot…")}
      </p>
      <noscript>
        <p class="text-sm text-error">{gettext("This check needs JavaScript.")}</p>
      </noscript>
    </div>
    """
  end
end
