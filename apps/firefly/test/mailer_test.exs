defmodule Firefly.MailerTest do
  # Not async: the mailer's config is node-wide.
  use Firefly.DataCase, async: false

  import Swoosh.TestAssertions

  alias Firefly.Mailer
  alias Firefly.Notifications.{EmailLog, Emails}

  defmodule Refusing do
    @moduledoc false
    use Swoosh.Adapter
    def deliver(_email, _config), do: {:error, {401, %{"errors" => ["bad key"]}}}
  end

  defmodule Down do
    @moduledoc false
    use Swoosh.Adapter
    def deliver(_email, _config), do: raise("the relay is down")
  end

  setup do
    config = Application.get_env(:firefly, Mailer)
    on_exit(fn -> Application.put_env(:firefly, Mailer, config) end)

    ref =
      :telemetry_test.attach_event_handlers(self(), [[:firefly, :mailer, :deliver, :stop]])

    on_exit(fn -> :telemetry.detach(ref) end)
    %{ref: ref}
  end

  defp use_adapter(adapter, config \\ []),
    do: Application.put_env(:firefly, Mailer, [adapter: adapter] ++ config)

  defp last_log, do: Repo.one(from(e in EmailLog, order_by: [desc: :id], limit: 1))

  test "a sent email is logged and measured by adapter", %{ref: ref} do
    assert {:ok, _} = Mailer.deliver_now(Emails.test_email("ops@example.com"))

    assert_email_sent(to: "ops@example.com")
    assert %{status: "sent", to: "ops@example.com", template: "test_email"} = last_log()

    assert_received {[:firefly, :mailer, :deliver, :stop], ^ref, %{duration: _},
                     %{adapter: "test", template: "test_email", result: "sent"}}
  end

  test "an adapter's error is returned and logged", %{ref: ref} do
    use_adapter(Refusing)

    assert {:error, {401, _}} = Mailer.deliver_now(Emails.test_email("ops@example.com"))

    assert %{status: "failed", error: error} = last_log()
    assert error == ~S|HTTP 401: %{"errors" => ["bad key"]}|

    assert_received {[:firefly, :mailer, :deliver, :stop], ^ref, _, %{result: "failed"}}
  end

  test "an adapter's exception is logged, then raised again" do
    use_adapter(Down)

    assert_raise RuntimeError, "the relay is down", fn ->
      Mailer.deliver_now(Emails.test_email("ops@example.com"))
    end

    assert %{status: "failed", error: "the relay is down"} = last_log()
  end

  test "an email without a recipient is skipped", %{ref: ref} do
    assert {:ok, :skipped} = Mailer.deliver_now(Emails.test_email(nil))

    assert_no_email_sent()
    assert %{status: "skipped"} = last_log()
    assert_received {[:firefly, :mailer, :deliver, :stop], ^ref, _, %{result: "skipped"}}
  end

  test "the config's provider options go with every email" do
    use_adapter(Swoosh.Adapters.Test, provider_options: %{message_stream: "broadcast"})

    {:ok, _} = Mailer.deliver_now(Emails.test_email("ops@example.com"))

    assert_email_sent(fn email -> email.provider_options == %{message_stream: "broadcast"} end)
  end

  test "names its adapter" do
    assert {Mailer.adapter(), Mailer.adapter_label()} == {"test", "Test"}

    for {adapter, name, label} <- [
          {Swoosh.Adapters.SMTP, "smtp", "SMTP"},
          {Swoosh.Adapters.AmazonSES, "ses", "Amazon SES"},
          {Swoosh.Adapters.Sendgrid, "sendgrid", "SendGrid"},
          {Swoosh.Adapters.Mailgun, "mailgun", "Mailgun"},
          {Swoosh.Adapters.Postmark, "postmark", "Postmark"},
          {Swoosh.Adapters.Local, "local", "Local"}
        ] do
      use_adapter(adapter)
      assert {Mailer.adapter(), Mailer.adapter_label()} == {name, label}
    end
  end
end
