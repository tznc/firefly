defmodule FirestormWeb.Web.InboundController do
  @moduledoc """
  SendGrid Inbound Parse webhook for reply-by-email.

  Configure SendGrid to POST to `/inbound/sendgrid?token=<FIREFLY_INBOUND_EMAIL_TOKEN>`.
  Requests without the shared token are rejected (and the endpoint is
  disabled when no token is configured). A reply is only posted when its
  reply-to address verifies (see `FirestormWeb.ReplyAddress`) and the sender
  matches the user the address was issued to.
  """
  use FirestormWeb.Web, :controller

  require Logger

  alias FirestormWeb.{Forums, Posting, ReplyAddress}

  # Get the email part out of something like "Jane Doe <jane@example.com>"
  @email_regex ~r/<?([^<>\s]+@[^<>\s]+)>?\s*$/

  plug(:verify_webhook_token)

  def sendgrid(conn, params) do
    with {:ok, thread_id, user_id} <- ReplyAddress.verify(params["to"]),
         %{} = user <- Forums.get_user(user_id),
         true <- sender_matches?(params["from"], user) || {:error, :sender_mismatch},
         # A merged thread's replies go where its posts went.
         %{} = thread <- Forums.get_thread_after_merges(thread_id),
         :ok <- Posting.check(user, thread),
         {:ok, _post} <- Forums.create_post(thread, user, %{body: params["text"]}) do
      :ok
    else
      reason -> Logger.info("Ignored inbound email: #{inspect(reason)}")
    end

    # Always 200 for authenticated requests, so SendGrid doesn't retry
    # emails we've deliberately ignored.
    send_resp(conn, 200, "ok")
  end

  defp sender_matches?(from, %{email: email}) when is_binary(from) and is_binary(email) do
    case Regex.run(@email_regex, String.trim(from)) do
      [_, address] -> String.downcase(address) == String.downcase(email)
      _ -> false
    end
  end

  defp sender_matches?(_from, _user), do: false

  defp verify_webhook_token(conn, _opts) do
    expected = Application.get_env(:firestorm_web, :email)[:inbound_token]
    given = conn.params["token"]

    cond do
      expected in [nil, ""] ->
        conn |> send_resp(404, "Not Found") |> halt()

      is_binary(given) and Plug.Crypto.secure_compare(given, expected) ->
        conn

      true ->
        conn |> send_resp(403, "Forbidden") |> halt()
    end
  end
end
