defmodule FireflyWeb.DigestController do
  @moduledoc """
  One-click unsubscribe from digest emails (RFC 8058): the mail client
  POSTs to the `List-Unsubscribe` URL, and digests are off. People who
  follow the link instead get `FireflyWeb.DigestLive.Unsubscribe`.
  """
  use FireflyWeb, :controller

  alias Firefly.Notifications.Digests

  def unsubscribe(conn, %{"token" => token}) do
    case Digests.unsubscribe(token) do
      {:ok, _user} -> text(conn, "Unsubscribed from digest emails.")
      {:error, _reason} -> conn |> put_status(:not_found) |> text("This link has expired.")
    end
  end
end
