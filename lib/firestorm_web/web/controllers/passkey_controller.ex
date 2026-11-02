defmodule FirestormWeb.Web.PasskeyController do
  @moduledoc """
  Logging in with a passkey (see `FirestormWeb.Passkeys`): `challenge`
  answers the `PasskeyLogin` hook with the options for
  `navigator.credentials.get` and keeps the challenge in the session;
  `create` checks the browser's answer (once per challenge) and logs in,
  with no second factor asked. Attempts count against the per-IP login
  limit.
  """
  use FirestormWeb.Web, :controller

  alias FirestormWeb.{Passkeys, RateLimit, WebAuthn}
  alias FirestormWeb.Web.Login

  def challenge(conn, _params) do
    if Passkeys.enabled?() do
      {challenge, options} = Passkeys.login_challenge()

      conn
      |> put_session(:passkey_challenge, WebAuthn.to_session(challenge))
      |> json(options)
    else
      conn |> put_status(:not_found) |> json(%{error: "Passkeys are off."})
    end
  end

  def create(conn, params) do
    stored = get_session(conn, :passkey_challenge)
    conn = delete_session(conn, :passkey_challenge)

    with :ok <- RateLimit.check(:login_ip, ip(conn)),
         {:ok, user} <- Passkeys.authenticate(stored, params["passkey"] || %{}) do
      Login.complete(conn, user, ~p"/login", :passkey)
    else
      {:error, :rate_limited} -> Login.fail(conn, ~p"/login", RateLimit.message())
      {:error, reason} -> Login.fail(conn, ~p"/login", Passkeys.message(reason))
    end
  end

  defp ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
