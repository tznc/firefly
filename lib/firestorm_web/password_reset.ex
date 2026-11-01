defmodule FirestormWeb.PasswordReset do
  @moduledoc """
  Password reset by email. Links carry a signed token bound to the user's
  current email and password hash, so they expire after an hour and stop
  working once the password changes (single use).
  """
  require Logger

  alias FirestormWeb.{Emails, Forums, Mailer, RateLimit}
  alias FirestormWeb.Forums.User
  alias FirestormWeb.Web.Endpoint

  @salt "password reset"
  @max_age 60 * 60

  def token(%User{} = user),
    do: Phoenix.Token.sign(Endpoint, @salt, {user.id, user.email, fingerprint(user)})

  def url(%User{} = user), do: FirestormWeb.Web.Paths.password_reset_url(token(user))

  @doc "The user a reset token is valid for."
  def verify(token) when is_binary(token) do
    with {:ok, {id, email, fingerprint}} <-
           Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age),
         %User{email: ^email} = user <- Forums.get_user(id),
         true <- Plug.Crypto.secure_compare(fingerprint(user), fingerprint) do
      {:ok, user}
    else
      _ -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :invalid}

  @doc """
  Emails reset links to the password accounts with this email address. Says
  nothing about whether any exist.
  """
  def deliver_instructions(email) when is_binary(email) do
    for user <- Forums.list_password_users_by_email(email),
        RateLimit.check_email(user) == :ok do
      deliver(user)
    end

    :ok
  end

  defp deliver(user) do
    user |> Emails.password_reset(url(user)) |> Mailer.deliver_now()
  rescue
    error -> Logger.error("Failed to send password reset email: #{Exception.message(error)}")
  end

  defp fingerprint(%User{password_hash: hash}) do
    digest = :crypto.hash(:sha256, hash || "")
    digest |> binary_part(0, 12) |> Base.url_encode64(padding: false)
  end
end
