defmodule FireflyWeb.DiscourseConnectProviderController do
  @moduledoc """
  `/session/sso_provider`: other sites logging their visitors in through
  this one (see `Firefly.Accounts.Auth.DiscourseConnectProvider`). A valid
  request from a logged-in member goes straight back with their details;
  anyone else logs in first and comes back here (unless the site asked
  with `prompt=none`, which gets `failed=true` instead). A `logout=true`
  request logs the member out here too, then goes back.
  """
  use FireflyWeb, :controller

  alias Firefly.Accounts.User
  alias Firefly.Accounts.Auth.DiscourseConnectProvider, as: Provider
  alias Firefly.Moderation.Penalties
  alias FireflyWeb.Login

  def show(conn, params) do
    with true <- Provider.enabled?() || {:error, :disabled},
         {:ok, request} <- Provider.verify(params["sso"], params["sig"]) do
      respond(conn, request, conn.assigns[:current_user])
    else
      {:error, :disabled} -> refuse(conn, "Logging in to other sites through this one is off.")
      {:error, reason} -> refuse(conn, Provider.message(reason))
    end
  end

  defp respond(conn, %{logout?: true} = request, _user) do
    case Provider.logout(request) do
      :ok ->
        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> redirect(external: request.return_url)

      {:error, reason} ->
        refuse(conn, Provider.message(reason))
    end
  end

  defp respond(conn, request, %User{} = user) do
    cond do
      User.suspended?(user) ->
        refuse(conn, Penalties.suspended_message(user))

      Provider.two_factor_required?(user) ->
        conn
        |> Login.put_return_to(current_path(conn))
        |> put_flash(
          :error,
          "Turn on two-factor authentication to log in to #{request.client.name} with this account."
        )
        |> redirect(to: ~p"/settings/security")

      true ->
        reply(conn, Provider.answer(request, user))
    end
  end

  defp respond(conn, %{prompt_none?: true} = request, nil),
    do: reply(conn, Provider.answer_failed(request))

  defp respond(conn, request, nil) do
    conn
    |> Login.put_return_to(current_path(conn))
    |> put_flash(:info, "Log in to continue to #{request.client.name}.")
    |> redirect(to: ~p"/login")
  end

  defp reply(conn, {:ok, url}), do: redirect(conn, external: url)
  defp reply(conn, {:error, reason}), do: refuse(conn, Provider.message(reason))

  defp refuse(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/")
  end
end
