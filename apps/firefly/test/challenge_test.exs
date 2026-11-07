defmodule Firefly.Security.ChallengeTest do
  # Turns the challenge and the jail on, for every test (application env).
  use Firefly.DataCase, async: false

  import Firefly.Fixtures

  alias Firefly.{Accounts, SiteSettings}
  alias Firefly.Security.{Challenge, Jail}

  @ip {198, 51, 100, 7}

  # A siteverify endpoint: success for the answer "good", and the request's form.
  defmodule ProviderStub do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, test: test) do
      {:ok, body, conn} = read_body(conn)
      form = URI.decode_query(body)
      send(test, {:siteverify, form})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{"success" => form["response"] == "good"}))
    end
  end

  defp put_config(key, value) do
    previous = Application.get_env(:firefly, key)
    Application.put_env(:firefly, key, value)
    on_exit(fn -> Application.put_env(:firefly, key, previous) end)
  end

  setup do
    put_config(Challenge, enabled: true)
    put_config(Jail, enabled: true)
    Jail.reset()
    on_exit(&Jail.reset/0)
    {:ok, admin: admin_fixture()}
  end

  defp set(settings, admin), do: {:ok, _} = SiteSettings.update(settings, admin)

  # What the BotChallenge hook sends back for `widget`.
  defp solve(%{mode: "pow", challenge: json}, change \\ & &1) do
    challenge = JSON.decode!(json)

    %Altcha.V1.Solution{number: number} =
      Altcha.V1.solve_challenge(
        challenge["challenge"],
        challenge["salt"],
        :sha256,
        challenge["maxnumber"]
      )

    challenge
    |> Map.delete("maxnumber")
    |> Map.put("number", number)
    |> change.()
    |> JSON.encode!()
    |> Base.encode64()
  end

  test "the proof of work is the default, and off is off", %{admin: admin} do
    assert Challenge.mode() == "pow"
    assert %{mode: "pow", challenge: json} = Challenge.widget()
    assert %{"algorithm" => "SHA-256", "maxnumber" => 100_000} = JSON.decode!(json)
    assert Challenge.script_sources() == []

    set(%{"bot_challenge" => "off"}, admin)
    refute Challenge.enabled?()
    assert Challenge.widget() == nil
    assert Challenge.verify(nil, @ip) == :ok

    put_config(Challenge, enabled: false)
    set(%{"bot_challenge" => "pow"}, admin)
    assert Challenge.mode() == "off"
  end

  test "a solved proof of work passes once" do
    answer = solve(Challenge.widget())
    assert Challenge.verify(answer, @ip) == :ok
    assert Challenge.verify(answer, @ip) == {:error, :bot_challenge}
    assert Jail.points(@ip, "bot") == 1
  end

  test "wrong, tampered, expired or malformed answers fail and feed the jail", %{admin: admin} do
    widget = Challenge.widget()

    for change <- [
          &Map.update!(&1, "number", fn n -> n + 1 end),
          &Map.put(&1, "signature", String.duplicate("0", 64)),
          &Map.put(&1, "number", "1"),
          &Map.put(&1, "algorithm", "SHA-1"),
          &Map.delete(&1, "salt")
        ] do
      assert Challenge.verify(solve(widget, change), @ip) == {:error, :bot_challenge}
    end

    for answer <- [nil, "", "not base64!", Base.encode64("[]"), Base.encode64("{")] do
      assert Challenge.verify(answer, @ip) == {:error, :bot_challenge}
    end

    # Another site's key (a different secret key base) signed it.
    other =
      Altcha.V1.create_challenge(%Altcha.V1.ChallengeOptions{hmac_key: "other", max_number: 1000})

    assert Challenge.verify(
             solve(%{mode: "pow", challenge: Altcha.V1.Challenge.to_json(other)}),
             @ip
           ) ==
             {:error, :bot_challenge}

    expired =
      Altcha.V1.create_challenge(%Altcha.V1.ChallengeOptions{
        hmac_key:
          Base.encode16(
            :crypto.mac(:hmac, :sha256, Firefly.Endpoint.secret_key_base(), "bot challenge")
          ),
        max_number: 1000,
        expires: System.system_time(:second) - 1
      })

    assert Challenge.verify(
             solve(%{mode: "pow", challenge: Altcha.V1.Challenge.to_json(expired)}),
             @ip
           ) ==
             {:error, :bot_challenge}

    # Twelve failures: over the bot jail's threshold.
    assert %{jail: "bot"} = Jail.banned(@ip)

    set(%{"bot_challenge_difficulty" => "5000"}, admin)
    assert %{"maxnumber" => 5000} = JSON.decode!(Challenge.widget().challenge)
  end

  describe "Turnstile and hCaptcha" do
    setup %{admin: admin} do
      {:ok, server} =
        start_supervised(
          {Bandit, plug: {ProviderStub, test: self()}, ip: {127, 0, 0, 1}, port: 0}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      put_config(Challenge, enabled: true, verify_url: "http://127.0.0.1:#{port}/siteverify")
      set(%{"bot_challenge" => "turnstile"}, admin)
      :ok
    end

    test "need a site key, then check answers with the provider", %{admin: admin} do
      assert Challenge.mode() == "pow"

      set(
        %{"bot_challenge_site_key" => "site-key", "bot_challenge_secret_key" => "secret"},
        admin
      )

      assert Challenge.mode() == "turnstile"

      assert %{
               mode: "turnstile",
               site_key: "site-key",
               script: "https://challenges.cloudflare.com/" <> _
             } =
               Challenge.widget()

      assert Challenge.script_sources() == ["https://challenges.cloudflare.com"]

      assert Challenge.verify("good", @ip) == :ok

      assert_received {:siteverify,
                       %{"secret" => "secret", "response" => "good", "remoteip" => "198.51.100.7"}}

      assert Challenge.verify("bad", @ip) == {:error, :bot_challenge}
      assert Challenge.verify("", @ip) == {:error, :bot_challenge}
      refute_received {:siteverify, %{"response" => ""}}
      assert Jail.points(@ip, "bot") == 2

      set(%{"bot_challenge" => "hcaptcha"}, admin)
      assert %{mode: "hcaptcha", script: "https://js.hcaptcha.com/" <> _} = Challenge.widget()
    end

    test "fail closed when the provider can't be reached", %{admin: admin} do
      set(%{"bot_challenge_site_key" => "site-key"}, admin)
      put_config(Challenge, enabled: true, verify_url: "http://127.0.0.1:1/siteverify")

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Challenge.verify("good", @ip) == {:error, :bot_challenge}
             end) =~ "couldn't be reached"
    end
  end

  test "logins need it after the threshold's failures, by account or address", %{admin: admin} do
    user = user_fixture()
    refute Challenge.required_for_login?(user.username, @ip)

    for _ <- 1..3, do: Jail.signal(@ip, "login_failure")
    assert Challenge.required_for_login?(nil, @ip)
    refute Challenge.required_for_login?(user.username, {198, 51, 100, 8})

    for _ <- 1..3, do: Firefly.Security.record("login.failure", user)

    assert Firefly.Security.recent_login_failures(Accounts.get_user!(user.id)) == 3
    assert Challenge.required_for_login?(user.username, {198, 51, 100, 8})

    set(%{"bot_challenge_login_failures" => "4"}, admin)
    refute Challenge.required_for_login?(user.username, {198, 51, 100, 8})

    set(%{"bot_challenge" => "off"}, admin)
    refute Challenge.required_for_login?(nil, @ip)
  end
end
