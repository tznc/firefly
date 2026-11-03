defmodule FireflyWeb.Api.V1.FallbackController do
  @moduledoc """
  Turns the `{:error, reason}` results API actions return into problem
  responses (see `FireflyWeb.Api.Problem`). Things the user may not see
  are `404`, as if they didn't exist.
  """
  use FireflyWeb, :controller

  alias Firefly.Moderation.Posting
  alias Firefly.RateLimit
  alias FireflyWeb.Api.Problem

  # Posting gate refusals (see Firefly.Moderation.Posting).
  @posting [:closed, :unconfirmed, :read_only]

  def call(conn, nil), do: Problem.send(conn, 404, "Not found.")
  def call(conn, {:error, :not_found}), do: Problem.send(conn, 404, "Not found.")
  def call(conn, {:error, %Ecto.Changeset{} = changeset}), do: Problem.changeset(conn, changeset)

  def call(conn, {:error, reason}) when reason in [:forbidden, :unauthorized],
    do:
      Problem.send(
        conn,
        403,
        FireflyWeb.Authorization.denied_message(conn.assigns[:current_user])
      )

  def call(conn, {:error, :rate_limited}), do: Problem.send(conn, 429, RateLimit.message())

  def call(conn, {:error, {:slow_mode, _wait} = reason}),
    do: Problem.send(conn, 429, Posting.message(reason))

  def call(conn, {:error, {penalty, _until} = reason}) when penalty in [:silenced, :suspended],
    do: Problem.send(conn, 403, Posting.message(reason))

  def call(conn, {:error, {:trust_level, _level} = reason}),
    do: Problem.send(conn, 403, Posting.message(reason))

  def call(conn, {:error, reason}) when reason in @posting,
    do: Problem.send(conn, 403, Posting.message(reason))

  def call(conn, {:error, {status, message}}) when is_integer(status) and is_binary(message),
    do: Problem.send(conn, status, message)

  def call(conn, {:error, message}) when is_binary(message), do: Problem.send(conn, 422, message)

  def call(conn, {:error, reason}),
    do: Problem.send(conn, 422, "The request failed: #{inspect(reason)}.")
end
