defmodule Firefly.Security.Challenge do
  @moduledoc """
  The bot challenge on sign-up, password-reset and login-link requests, and
  on password logins after `bot_challenge_login_failures` recent failures
  (per account or address). No visual puzzle.

  The `bot_challenge` setting picks how:

    * `pow` (default): a self-hosted proof of work,
      [ALTCHA](https://altcha.org)'s original scheme (the `altcha` package,
      V1): the server hands out a random salt and the SHA-256 of salt +
      a secret number below `bot_challenge_difficulty`, HMAC-signed with a
      key derived from the secret key base and good for 20 minutes; the
      browser finds the number (the `BotChallenge` hook, a second or two)
      and sends it back. Verified here: the signature, the hash, the expiry
      (checked here, since `altcha` 2.2.0's own check doesn't take effect),
      and that the challenge wasn't used before (a replay cache in ETS on
      each node, see `Firefly.Security.Jail.Tables`). Nothing leaves the
      site and nothing is tracked.
    * `turnstile` or `hcaptcha`: Cloudflare Turnstile or hCaptcha, with
      the `bot_challenge_site_key` and the secret `bot_challenge_secret_key`
      settings; their answer is checked with the provider's `siteverify`.
      (hCaptcha may show some visitors a puzzle; Turnstile and the proof of
      work don't.)
    * `off`.

  Every failed check is a `bot_challenge` signal for the jail. Tests turn
  the challenge off with `config :firefly, Firefly.Security.Challenge,
  enabled: false`, and can point `verify_url` at a stub provider.
  """

  require Logger

  alias Firefly.{Accounts, Endpoint, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Security.Jail
  alias Firefly.Security.Jail.Tables

  @lifetime_seconds 20 * 60

  @providers %{
    "turnstile" => %{
      script: "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit",
      sources: ["https://challenges.cloudflare.com"],
      verify: "https://challenges.cloudflare.com/turnstile/v0/siteverify"
    },
    "hcaptcha" => %{
      script: "https://js.hcaptcha.com/1/api.js?render=explicit",
      sources: ["https://hcaptcha.com", "https://*.hcaptcha.com"],
      verify: "https://api.hcaptcha.com/siteverify"
    }
  }

  @doc "The challenge in use: `\"pow\"`, `\"turnstile\"`, `\"hcaptcha\"` or `\"off\"`."
  def mode do
    if Keyword.get(config(), :enabled, true), do: setting_mode(), else: "off"
  end

  defp config, do: Application.get_env(:firefly, __MODULE__, [])

  defp setting_mode do
    case SiteSettings.get("bot_challenge") do
      provider when is_map_key(@providers, provider) ->
        if SiteSettings.get("bot_challenge_site_key") != "", do: provider, else: "pow"

      mode ->
        mode
    end
  end

  @doc "Whether forms ask for the challenge."
  def enabled?, do: mode() != "off"

  @doc """
  What a form's widget needs: `%{mode: "pow", challenge: json}`, `%{mode:
  provider, site_key, script}`, or nil when the challenge is off.
  """
  def widget do
    case mode() do
      "off" ->
        nil

      "pow" ->
        %{mode: "pow", challenge: new_pow()}

      provider ->
        %{
          mode: provider,
          site_key: SiteSettings.get("bot_challenge_site_key"),
          script: @providers[provider].script
        }
    end
  end

  @doc "The script sources the pages' CSP must allow for the challenge's widget."
  def script_sources do
    case @providers[mode()] do
      nil -> []
      provider -> provider.sources
    end
  end

  # A new challenge, as the JSON the browser solves.
  defp new_pow do
    challenge =
      Altcha.V1.create_challenge(%Altcha.V1.ChallengeOptions{
        hmac_key: hmac_key(),
        max_number: SiteSettings.get("bot_challenge_difficulty"),
        expires: System.system_time(:second) + @lifetime_seconds
      })

    Altcha.V1.Challenge.to_json(challenge)
  end

  defp hmac_key,
    do: Base.encode16(:crypto.mac(:hmac, :sha256, Endpoint.secret_key_base(), "bot challenge"))

  @doc """
  Checks a form's answer to the challenge (`response`, the `bot_challenge`
  field) from `ip`: `:ok` or `{:error, :bot_challenge}` (also a jail
  signal). Always `:ok` when the challenge is off.
  """
  def verify(response, ip) do
    result =
      case mode() do
        "off" -> :ok
        "pow" -> verify_pow(response)
        provider -> verify_provider(provider, response, ip)
      end

    case result do
      :ok ->
        :ok

      :error ->
        Jail.signal(ip, "bot_challenge")
        {:error, :bot_challenge}
    end
  end

  defp verify_pow(response) when is_binary(response) and response != "" do
    with {:ok, json} <- Base.decode64(response),
         {:ok, %{} = answer} <- Jason.decode(json),
         {:ok, payload} <- payload(answer),
         true <- Altcha.V1.verify_solution(payload, hmac_key(), false),
         true <- unexpired?(payload),
         :ok <- first_use(payload.salt) do
      :ok
    else
      _ -> :error
    end
  end

  defp verify_pow(_response), do: :error

  # Built here rather than with Altcha.V1.Payload.from_json/1 (`altcha`
  # 2.2.0), which makes an atom of every key the browser sends.
  defp payload(%{
         "algorithm" => "SHA-256",
         "challenge" => challenge,
         "number" => number,
         "salt" => salt,
         "signature" => signature
       })
       when is_binary(challenge) and is_integer(number) and is_binary(salt) and
              is_binary(signature) do
    {:ok,
     %Altcha.V1.Payload{
       algorithm: :sha256,
       challenge: challenge,
       number: number,
       salt: salt,
       signature: signature
     }}
  end

  defp payload(_answer), do: :error

  # Checked here because `altcha` 2.2.0's own expiry check has no effect.
  defp unexpired?(payload) do
    case Integer.parse(Altcha.V1.extract_params(payload)["expires"] || "") do
      {expires, ""} -> System.system_time(:second) <= expires
      _none -> false
    end
  end

  # Each challenge is good once, until it would have expired anyway.
  defp first_use(salt) do
    until = System.system_time(:second) + @lifetime_seconds

    if :ets.insert_new(Tables.challenges(), {salt, until}), do: :ok, else: :error
  end

  defp verify_provider(provider, response, ip) when is_binary(response) and response != "" do
    form = %{
      secret: SiteSettings.get("bot_challenge_secret_key"),
      response: response,
      remoteip: ip && ip |> Firefly.IPRange.address() |> format_ip()
    }

    url = Keyword.get(config(), :verify_url, @providers[provider].verify)

    case Req.post(url, form: form, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200, body: %{"success" => true}}} ->
        :ok

      {:ok, %{body: body}} ->
        Logger.info("#{provider} refused a bot challenge answer: #{inspect(body["error-codes"])}")
        :error

      {:error, reason} ->
        # Fail closed: an answer that can't be checked isn't an answer.
        Logger.warning("#{provider} couldn't be reached to check a challenge: #{inspect(reason)}")
        :error
    end
  end

  defp verify_provider(_provider, _response, _ip), do: :error

  defp format_ip(nil), do: nil
  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()

  @doc """
  Whether a password login for `username` from `ip` must answer the
  challenge: after `bot_challenge_login_failures` recent failures of the
  account or the address.
  """
  def required_for_login?(username, ip) do
    threshold = SiteSettings.get("bot_challenge_login_failures")

    enabled?() and
      (Jail.points(ip, "auth") >= threshold or account_failures(username) >= threshold)
  end

  defp account_failures(username) when is_binary(username) and username != "" do
    case Accounts.get_user_by_username(username) do
      %User{} = user -> Firefly.Security.recent_login_failures(user)
      nil -> 0
    end
  end

  defp account_failures(_username), do: 0

  @doc "The challenge settings (Security > Bot challenge)."
  def setting_definitions do
    [
      %{
        key: "bot_challenge",
        section: "Bot challenge",
        type: :select,
        label: "Bot challenge",
        default: "pow",
        options: [
          {"Proof of work (self-hosted, no puzzle)", "pow"},
          {"Cloudflare Turnstile", "turnstile"},
          {"hCaptcha", "hcaptcha"},
          {"Off", "off"}
        ],
        help:
          "Asked on sign-up, password reset and login link requests, and on logins after failures. Turnstile and hCaptcha need their keys below (without them, proof of work is used)."
      },
      %{
        key: "bot_challenge_site_key",
        section: "Bot challenge",
        type: :text,
        label: "Turnstile or hCaptcha site key",
        default: "",
        help: "The public key from the provider's dashboard."
      },
      %{
        key: "bot_challenge_secret_key",
        section: "Bot challenge",
        type: :text,
        secret: true,
        label: "Turnstile or hCaptcha secret key",
        default: "",
        help: "The secret key, for checking answers with the provider."
      },
      %{
        key: "bot_challenge_difficulty",
        section: "Bot challenge",
        type: :integer,
        label: "Proof of work difficulty",
        default: 100_000,
        min: 1_000,
        max: 10_000_000,
        help:
          "The largest secret number the browser searches for: about a second on a phone at the default, ten times longer at ten times the number."
      },
      %{
        key: "bot_challenge_login_failures",
        section: "Bot challenge",
        type: :integer,
        label: "Ask on logins after this many failures",
        default: 3,
        min: 1,
        max: 100,
        help:
          "Failed logins of the account in the last 15 minutes, or the address's points in the auth jail."
      }
    ]
  end
end
