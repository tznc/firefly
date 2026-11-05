defmodule Firefly.MailConfigTest do
  @moduledoc """
  The mail adapter `config/runtime.exs` builds from the environment.
  """
  # Not async: it sets environment variables.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  @vars ~w(FIREFLY_MAIL_ADAPTER FIREFLY_SENDGRID_API_KEY FIREFLY_SMTP_RELAY FIREFLY_SMTP_PORT
           FIREFLY_SMTP_USERNAME FIREFLY_SMTP_PASSWORD FIREFLY_SMTP_TLS FIREFLY_SMTP_SSL
           FIREFLY_SMTP_AUTH FIREFLY_SMTP_RETRIES FIREFLY_SMTP_VERIFY FIREFLY_SMTP_CA_CERT_FILE
           FIREFLY_SES_REGION AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID
           AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN FIREFLY_SES_CONFIGURATION_SET
           FIREFLY_MAILGUN_API_KEY FIREFLY_MAILGUN_DOMAIN FIREFLY_MAILGUN_BASE_URL
           FIREFLY_POSTMARK_API_KEY FIREFLY_POSTMARK_MESSAGE_STREAM
           FIREFLY_DATABASE_URL FIREFLY_SECRET_KEY_BASE)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      for {var, value} <- saved,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
    end)

    # What production needs besides mail.
    System.put_env("FIREFLY_DATABASE_URL", "ecto://u:p@localhost/firefly")
    System.put_env("FIREFLY_SECRET_KEY_BASE", String.duplicate("k", 64))
  end

  defp mailer(env \\ :prod, vars) do
    System.put_env(vars)
    Config.Reader.read!(@runtime, env: env)[:firefly][Firefly.Mailer]
  end

  defp fails(vars, message) do
    error = assert_raise RuntimeError, fn -> mailer(vars) end
    assert error.message =~ message
  end

  test "production won't start without an adapter" do
    fails(%{}, "no outbound email is configured: set FIREFLY_MAIL_ADAPTER")
    # A provider's key alone doesn't pick an adapter.
    fails(%{"FIREFLY_SENDGRID_API_KEY" => "SG.key"}, "set FIREFLY_MAIL_ADAPTER")
  end

  test "development keeps the local mailbox, unless told otherwise" do
    assert mailer(:dev, %{}) == nil

    assert mailer(:dev, %{"FIREFLY_MAIL_ADAPTER" => "smtp", "FIREFLY_SMTP_RELAY" => "mail"})[
             :adapter
           ] ==
             Swoosh.Adapters.SMTP
  end

  test "an unknown adapter fails" do
    fails(%{"FIREFLY_MAIL_ADAPTER" => "pigeon"}, "FIREFLY_MAIL_ADAPTER=pigeon isn't one of smtp")
  end

  describe "SMTP" do
    test "STARTTLS with verified certificates by default" do
      config =
        mailer(%{
          "FIREFLY_MAIL_ADAPTER" => "smtp",
          "FIREFLY_SMTP_RELAY" => "smtp.example.com",
          "FIREFLY_SMTP_USERNAME" => "forum",
          "FIREFLY_SMTP_PASSWORD" => "s3cret"
        })

      assert config[:adapter] == Swoosh.Adapters.SMTP

      assert Keyword.take(config, ~w(relay port username password ssl tls auth retries)a) == [
               relay: "smtp.example.com",
               port: 587,
               username: "forum",
               password: "s3cret",
               ssl: false,
               tls: :always,
               auth: :if_available,
               retries: 2
             ]

      tls = config[:tls_options]
      assert tls[:verify] == :verify_peer
      assert tls[:server_name_indication] == ~c"smtp.example.com"
      assert [_ | _] = tls[:cacerts]
      assert is_function(tls[:customize_hostname_check][:match_fun])
      assert config[:sockopts] == []
    end

    test "implicit TLS, a CA file, and the options" do
      config =
        mailer(%{
          "FIREFLY_MAIL_ADAPTER" => "smtp",
          "FIREFLY_SMTP_RELAY" => "smtp.example.com",
          "FIREFLY_SMTP_SSL" => "true",
          "FIREFLY_SMTP_AUTH" => "always",
          "FIREFLY_SMTP_RETRIES" => "5",
          "FIREFLY_SMTP_CA_CERT_FILE" => "/etc/ssl/relay.pem"
        })

      assert {config[:ssl], config[:port], config[:tls]} == {true, 465, :never}
      assert {config[:auth], config[:retries]} == {:always, 5}
      assert config[:sockopts][:cacertfile] == "/etc/ssl/relay.pem"
      assert config[:sockopts][:verify] == :verify_peer
    end

    test "verification can be turned off, and TLS too" do
      config =
        mailer(%{
          "FIREFLY_MAIL_ADAPTER" => "smtp",
          "FIREFLY_SMTP_RELAY" => "localhost",
          "FIREFLY_SMTP_PORT" => "25",
          "FIREFLY_SMTP_TLS" => "never",
          "FIREFLY_SMTP_VERIFY" => "false"
        })

      assert {config[:port], config[:tls]} == {25, :never}
      assert config[:tls_options] == [verify: :verify_none]
    end

    test "needs a relay, and known modes" do
      fails(%{"FIREFLY_MAIL_ADAPTER" => "smtp"}, "FIREFLY_SMTP_RELAY is missing")

      fails(
        %{
          "FIREFLY_MAIL_ADAPTER" => "smtp",
          "FIREFLY_SMTP_RELAY" => "mail",
          "FIREFLY_SMTP_TLS" => "sometimes"
        },
        "FIREFLY_SMTP_TLS=sometimes isn't one of"
      )
    end
  end

  describe "Amazon SES" do
    test "with the standard AWS variables" do
      config =
        mailer(%{
          "FIREFLY_MAIL_ADAPTER" => "ses",
          "AWS_REGION" => "eu-west-1",
          "AWS_ACCESS_KEY_ID" => "AKID",
          "AWS_SECRET_ACCESS_KEY" => "secret",
          "AWS_SESSION_TOKEN" => "token",
          "FIREFLY_SES_CONFIGURATION_SET" => "transactional"
        })

      assert config[:adapter] == Swoosh.Adapters.AmazonSES

      assert {config[:region], config[:access_key], config[:secret]} ==
               {"eu-west-1", "AKID", "secret"}

      assert config[:provider_options] == %{
               security_token: "token",
               configuration_set_name: "transactional"
             }
    end

    test "FIREFLY_SES_REGION wins; credentials are required" do
      vars = %{
        "FIREFLY_MAIL_ADAPTER" => "ses",
        "FIREFLY_SES_REGION" => "us-east-1",
        "AWS_REGION" => "eu-west-1"
      }

      fails(vars, "AWS_ACCESS_KEY_ID is missing")

      config =
        mailer(Map.merge(vars, %{"AWS_ACCESS_KEY_ID" => "a", "AWS_SECRET_ACCESS_KEY" => "b"}))

      assert {config[:region], config[:provider_options]} == {"us-east-1", %{}}
    end
  end

  test "SendGrid" do
    expected = [adapter: Swoosh.Adapters.Sendgrid, api_key: "SG.key"]

    assert mailer(%{"FIREFLY_MAIL_ADAPTER" => "sendgrid", "FIREFLY_SENDGRID_API_KEY" => "SG.key"}) ==
             expected

    System.delete_env("FIREFLY_SENDGRID_API_KEY")
    fails(%{"FIREFLY_MAIL_ADAPTER" => "sendgrid"}, "FIREFLY_SENDGRID_API_KEY is missing")
  end

  test "Mailgun" do
    config =
      mailer(%{
        "FIREFLY_MAIL_ADAPTER" => "mailgun",
        "FIREFLY_MAILGUN_API_KEY" => "key",
        "FIREFLY_MAILGUN_DOMAIN" => "mg.example.com",
        "FIREFLY_MAILGUN_BASE_URL" => "https://api.eu.mailgun.net/v3"
      })

    assert config == [
             adapter: Swoosh.Adapters.Mailgun,
             api_key: "key",
             domain: "mg.example.com",
             base_url: "https://api.eu.mailgun.net/v3"
           ]

    fails(
      %{"FIREFLY_MAIL_ADAPTER" => "mailgun", "FIREFLY_MAILGUN_DOMAIN" => nil},
      "FIREFLY_MAILGUN_DOMAIN is missing"
    )
  end

  test "Postmark" do
    config =
      mailer(%{
        "FIREFLY_MAIL_ADAPTER" => "postmark",
        "FIREFLY_POSTMARK_API_KEY" => "token",
        "FIREFLY_POSTMARK_MESSAGE_STREAM" => "outbound"
      })

    assert config == [
             adapter: Swoosh.Adapters.Postmark,
             api_key: "token",
             provider_options: %{message_stream: "outbound"}
           ]
  end

  test "local" do
    assert mailer(%{"FIREFLY_MAIL_ADAPTER" => "local"}) == [adapter: Swoosh.Adapters.Local]
  end
end
