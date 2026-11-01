defmodule FirestormWeb.ReplyAddress do
  @moduledoc """
  Signed reply-by-email addresses.

  Each notification email gets a reply-to address that names the thread and
  the recipient, signed with a key derived from the endpoint's
  `secret_key_base`:

      reply+<thread id>-<user id>-<signature>@<inbound domain>

  An inbound email is only accepted if its address verifies, so replies can't
  be forged for other threads or users, and the poster is the user the email
  was sent to rather than whatever the (spoofable) From header claims.
  """

  @salt "firefly reply-by-email v1"

  @doc "The reply-to address for `user` replying to `thread`."
  def address(%{id: thread_id}, %{id: user_id}) do
    "reply+#{thread_id}-#{user_id}-#{signature(thread_id, user_id)}@#{domain()}"
  end

  @doc """
  Finds and verifies a reply address in a To header (which may hold several
  addresses). Returns `{:ok, thread_id, user_id}` or `:error`.
  """
  def verify(to) when is_binary(to) do
    pattern = ~r/reply\+(\d+)-(\d+)-([a-z2-7]+)@#{Regex.escape(domain())}/i

    with [_, thread_id, user_id, sig] <- Regex.run(pattern, to),
         {thread_id, ""} <- Integer.parse(thread_id),
         {user_id, ""} <- Integer.parse(user_id),
         true <- Plug.Crypto.secure_compare(String.downcase(sig), signature(thread_id, user_id)) do
      {:ok, thread_id, user_id}
    else
      _ -> :error
    end
  end

  def verify(_), do: :error

  @doc "The domain inbound replies are sent to."
  def domain, do: Application.fetch_env!(:firestorm_web, :email)[:reply_domain]

  defp signature(thread_id, user_id) do
    :hmac
    |> :crypto.mac(:sha256, key(), "#{thread_id}:#{user_id}")
    |> binary_part(0, 15)
    |> Base.encode32(case: :lower, padding: false)
  end

  defp key do
    secret = FirestormWeb.Web.Endpoint.config(:secret_key_base)
    Plug.Crypto.KeyGenerator.generate(secret, @salt, length: 32, cache: Plug.Crypto.Keys)
  end
end
