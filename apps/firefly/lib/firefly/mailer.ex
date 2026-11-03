defmodule Firefly.Mailer do
  @moduledoc """
  Sends email through Bamboo (the adapter is `config :firefly,
  Firefly.Mailer`) and records every attempt in the email log staff read
  at `/staff/emails` (see `Firefly.Notifications.EmailLog`): sent, skipped
  (no recipient) or failed, with the error.
  """

  alias Firefly.Notifications.EmailLog

  @doc "Sends `email` now: Bamboo's result (an exception is logged, then raised again)."
  def deliver_now(%Bamboo.Email{} = email, opts \\ []) do
    config = Bamboo.Mailer.build_config(__MODULE__, :firefly)
    result = Bamboo.Mailer.deliver_now(config.adapter, email, config, opts)
    EmailLog.record(email, result)
    result
  rescue
    error ->
      EmailLog.record(email, {:error, error})
      reraise error, __STACKTRACE__
  end
end
