defmodule Firefly.Accounts.PasswordReset do
  @moduledoc """
  Password reset by email. Links carry a signed token bound to the user's
  current email and password hash, so they expire (after the
  `password_reset_hours` setting) and stop working once the password
  changes (single use).
  """
  require Logger

  alias Firefly.{Accounts, Mailer, RateLimit}
  alias Firefly.Notifications.Emails
  alias Firefly.Accounts.User
  alias Firefly.Endpoint

  @salt "password reset"

  def token(%User{} = user),
    do: Endpoint.sign(@salt, {user.id, user.email, fingerprint(user)})

  def url(%User{} = user), do: Firefly.URLs.password_reset_url(token(user))

  @doc "The user a reset token is valid for."
  def verify(token) when is_binary(token) do
    with {:ok, {id, email, fingerprint}} <-
           Endpoint.verify(@salt, token,
             max_age: Firefly.SiteSettings.get("password_reset_hours") * 3600
           ),
         %User{email: ^email} = user <- Accounts.get_user(id),
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
    for user <- Accounts.list_password_users_by_email(email),
        RateLimit.check_email(user) == :ok do
      deliver(user)
    end

    :ok
  end

  @doc """
  Emails `user` a reset link, as staff do from the users admin (no rate
  limit: staff chose to). `:ok`, or `{:error, reason}` when it couldn't be
  sent.
  """
  def deliver(%User{email: email} = user) when is_binary(email) do
    case user |> Emails.password_reset(url(user)) |> Mailer.deliver_now() do
      {:error, error} -> {:error, error}
      _sent -> :ok
    end
  rescue
    error ->
      Logger.error("Failed to send password reset email: #{Exception.message(error)}")
      {:error, error}
  end

  def deliver(%User{}), do: {:error, :no_email}

  defp fingerprint(%User{password_hash: hash}) do
    digest = :crypto.hash(:sha256, hash || "")
    digest |> binary_part(0, 12) |> Base.url_encode64(padding: false)
  end
end
