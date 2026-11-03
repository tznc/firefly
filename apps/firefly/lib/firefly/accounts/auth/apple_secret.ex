defmodule Firefly.Accounts.Auth.AppleSecret do
  @moduledoc """
  Sign in with Apple's client secret: a JWT signed with the private key
  Apple issued (configured as `Firefly.Accounts.Auth.AppleSecret`: `team_id`,
  `key_id`, `private_key`). Signing on every login is wasteful, so it's
  kept in `:persistent_term` and made again a day before it expires.
  """

  # Apple accepts at most 6 months.
  @lifetime 86_400 * 180
  @key {__MODULE__, :secret}

  @doc "The current secret (`config`: the strategy's client options, for its client id)."
  def client_secret(config) do
    now = System.os_time(:second)

    case :persistent_term.get(@key, nil) do
      {secret, expires_at} when expires_at - 86_400 > now ->
        secret

      _missing_or_expiring ->
        settings = Application.fetch_env!(:firefly, __MODULE__)

        secret =
          UeberauthApple.generate_client_secret(%{
            client_id: config[:client_id],
            expires_in: @lifetime,
            key_id: settings[:key_id],
            team_id: settings[:team_id],
            private_key: settings[:private_key]
          })

        :persistent_term.put(@key, {secret, now + @lifetime})
        secret
    end
  end
end
