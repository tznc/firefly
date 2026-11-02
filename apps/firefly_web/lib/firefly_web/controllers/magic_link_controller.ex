defmodule FireflyWeb.MagicLinkController do
  @moduledoc """
  Uses an emailed login link (see `Firefly.Accounts.MagicLinks`), from the
  button on its page (`AuthLive.MagicLinkConfirm`): logs in, or asks for
  the second factor first.
  """
  use FireflyWeb, :controller

  alias Firefly.Accounts.MagicLinks
  alias FireflyWeb.Login

  def create(conn, %{"token" => token}) do
    case MagicLinks.redeem(token) do
      {:ok, user} ->
        Login.complete(conn, user, ~p"/login", :magic_link)

      {:error, :invalid} ->
        Login.fail(conn, ~p"/login/email", "That link expired or was used already.")

      {:error, reason} ->
        Login.fail(conn, ~p"/login", reason)
    end
  end
end
