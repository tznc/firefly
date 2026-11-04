defmodule Firefly.Mailer do
  @moduledoc """
  Sends email through Swoosh, with the adapter `config :firefly,
  Firefly.Mailer` names (SMTP, Amazon SES, SendGrid, Mailgun, Postmark or
  local; set from the environment in `config/runtime.exs`), and records
  every attempt in the email log staff read at `/staff/emails` (see
  `Firefly.Notifications.EmailLog`): sent, skipped (no recipient) or
  failed, with the adapter's error.

  The config's `provider_options` (e.g. SES's configuration set and session
  token, Postmark's message stream) are added to every email. Each send is
  a `[:firefly, :mailer, :deliver]` span (see `Firefly.Telemetry`) with the
  adapter, the template and the outcome.
  """

  use Swoosh.Mailer, otp_app: :firefly

  alias Firefly.Notifications.EmailLog

  @adapters %{
    Swoosh.Adapters.SMTP => "smtp",
    Swoosh.Adapters.AmazonSES => "ses",
    Swoosh.Adapters.Sendgrid => "sendgrid",
    Swoosh.Adapters.Mailgun => "mailgun",
    Swoosh.Adapters.Postmark => "postmark",
    Swoosh.Adapters.Local => "local",
    Swoosh.Adapters.Test => "test"
  }

  @doc """
  Sends `email` now: `{:ok, metadata}` or `{:error, reason}` (an exception
  is logged, then raised again). An email without a recipient isn't sent
  (`{:ok, :skipped}`).
  """
  @spec deliver_now(Swoosh.Email.t(), keyword) :: {:ok, term} | {:error, term}
  def deliver_now(%Swoosh.Email{} = email, opts \\ []) do
    metadata = %{adapter: adapter(), template: email.private[:template] || "other"}

    Firefly.Telemetry.span([:firefly, :mailer, :deliver], metadata, fn ->
      result = send_email(email, opts)
      {result, %{result: outcome(email, result)}}
    end)
  end

  defp send_email(email, opts) do
    result =
      if EmailLog.recipients(email) == "",
        do: {:ok, :skipped},
        else: email |> with_provider_options() |> deliver(opts)

    EmailLog.record(email, result)
    result
  rescue
    error ->
      EmailLog.record(email, {:error, error})
      reraise error, __STACKTRACE__
  end

  defp outcome(email, result) do
    cond do
      EmailLog.recipients(email) == "" -> "skipped"
      match?({:ok, _}, result) -> "sent"
      true -> "failed"
    end
  end

  defp with_provider_options(email) do
    Enum.reduce(config()[:provider_options] || %{}, email, fn {key, value}, email ->
      Swoosh.Email.put_provider_option(email, key, value)
    end)
  end

  @doc """
  The configured adapter's short name (`"smtp"`, `"ses"`, `"sendgrid"`,
  `"mailgun"`, `"postmark"`, `"local"`, `"test"`), or the module's for
  another.
  """
  @spec adapter() :: String.t()
  def adapter do
    adapter = config()[:adapter]
    Map.get(@adapters, adapter) || inspect(adapter)
  end

  @doc "The configured adapter's name for people: `\"SMTP\"`, `\"Amazon SES\"`..."
  @spec adapter_label() :: String.t()
  def adapter_label do
    case adapter() do
      "smtp" -> "SMTP"
      "ses" -> "Amazon SES"
      "sendgrid" -> "SendGrid"
      "mailgun" -> "Mailgun"
      "postmark" -> "Postmark"
      "local" -> "Local"
      "test" -> "Test"
      other -> other
    end
  end

  defp config, do: Application.get_env(:firefly, __MODULE__, [])
end
