defmodule FirestormWeb.EmailConfirmation do
  @moduledoc """
  Email address confirmation. Links carry a signed token for the user's id and
  current email, so changing the email invalidates older links.
  """
  require Logger

  alias FirestormWeb.{Emails, Forums, Mailer}
  alias FirestormWeb.Forums.User
  alias FirestormWeb.Web.Endpoint

  @salt "email confirmation"
  @max_age 7 * 24 * 60 * 60

  def token(%User{id: id, email: email}), do: Phoenix.Token.sign(Endpoint, @salt, {id, email})

  def url(%User{} = user), do: FirestormWeb.Web.Paths.confirmation_url(token(user))

  @doc "Confirms the user the token was issued for, if their email hasn't changed since."
  def confirm(token) when is_binary(token) do
    with {:ok, {id, email}} <- Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age),
         %User{email: ^email} = user <- Forums.get_user(id) do
      Forums.confirm_user(user)
    else
      _ -> {:error, :invalid}
    end
  end

  @doc "Emails the user a confirmation link. Delivery failures are logged, not raised."
  def deliver(%User{email: email} = user) when is_binary(email) do
    user |> Emails.confirmation(url(user)) |> Mailer.deliver_now()
    :ok
  rescue
    error ->
      Logger.error("Failed to send confirmation email: #{Exception.message(error)}")
      {:error, :delivery_failed}
  end

  def deliver(%User{}), do: {:error, :no_email}
end
