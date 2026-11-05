defmodule FireflyWeb.PasswordComponents do
  @moduledoc """
  The password strength meter of the forms that set a password
  (registration, password reset, invitations): zxcvbn's score, computed on
  the server as the member types (the forms validate on change, see
  `Firefly.Accounts.Passwords.strength/2`), as a meter and in words.
  """
  use Phoenix.Component
  use Gettext, backend: FireflyWeb.Gettext

  alias Firefly.Accounts.Passwords

  attr :id, :string, required: true
  attr :password, :any, required: true, doc: "the password typed so far"
  attr :words, :list, default: [], doc: "what an attacker would try (username, email)"

  @doc "How strong the password typed so far is, with the site's minimum."
  def strength_meter(assigns) do
    assigns =
      assign(assigns,
        strength: Passwords.strength(assigns.password, assigns.words),
        minimum: Firefly.SiteSettings.get("min_password_score")
      )

    ~H"""
    <div :if={is_binary(@password) and @password != ""} id={@id} class="space-y-1" aria-live="polite">
      <progress
        class={["progress w-full", meter_class(@strength.score, @minimum)]}
        value={@strength.score + 1}
        max="5"
        aria-label={gettext("Password strength")}
      >
      </progress>
      <p class="text-sm">
        {gettext("Password strength: %{label}", label: label(@strength.score))}
        <span :if={@strength.score < @minimum}>
          · {gettext("too easy to guess: add words or make it longer")}
        </span>
      </p>
    </div>
    """
  end

  defp meter_class(score, minimum) when score < minimum, do: "progress-error"
  defp meter_class(score, _minimum) when score >= 4, do: "progress-success"
  defp meter_class(_score, _minimum), do: "progress-warning"

  defp label(0), do: gettext("very weak")
  defp label(1), do: gettext("weak")
  defp label(2), do: gettext("fair")
  defp label(3), do: gettext("good")
  defp label(4), do: gettext("strong")
end
