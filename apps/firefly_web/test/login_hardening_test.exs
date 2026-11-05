defmodule FireflyWeb.LoginHardeningTest do
  # Changes global config (the breach check's address, which local
  # addresses may be reached, login delays, the jail).
  use FireflyWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Firefly.DataCase, only: [errors_on: 1]
  import Swoosh.TestAssertions

  alias Firefly.{Accounts, Repo, Security, SiteSettings}
  alias Firefly.Accounts.{Passwords, User, UserSessions}
  alias Firefly.Notifications.EmailWorker
  alias Firefly.Plugins.HTTP
  alias Firefly.Security.Jail

  # Pwned Passwords' range API: the suffixes of one breached password.
  defmodule PwnedStub do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/range/" <> prefix} = conn, test: test) do
      send(test, {:range, prefix})
      <<_::binary-5, suffix::binary>> = hash("tangerine-otter-galaxy-42")

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, "0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n#{suffix}:52\r\n")
    end

    def hash(password), do: :crypto.hash(:sha, password) |> Base.encode16()
  end

  @strong "tangerine-otter-galaxy"

  defp register(password, username \\ "member#{System.unique_integer([:positive])}") do
    Accounts.register_user(%{
      username: username,
      email: "#{username}@example.com",
      password: password
    })
  end

  defp put_config(app, key, value) do
    previous = Application.get_env(app, key)
    Application.put_env(app, key, value)
    on_exit(fn -> Application.put_env(app, key, previous) end)
  end

  describe "password strength" do
    test "scores passwords, counting the username and email against them" do
      assert %{score: 0, label: "very weak"} = Passwords.strength("password")
      assert %{score: score} = Passwords.strength("correct horse battery staple violin")
      assert score >= 3

      # zxcvbn raises on some non-ASCII passwords; they get a brute-force estimate.
      assert %{score: score} = Passwords.strength("aあéagl99")
      assert score in 0..4
      assert %{score: 0} = Passwords.strength(<<0xED, 0x92, 0x92>>)

      assert Passwords.strength("zebrafish1989", ["zebrafish1989"]).score <
               Passwords.strength("zebrafish1989").score
    end

    test "refuses passwords below the minimum score", %{conn: _conn} do
      assert {:error, changeset} = register("password1234")
      assert "is too easy to guess: add words or make it longer" in errors_on(changeset).password

      assert {:ok, _} = register(@strong)
      {:ok, _} = SiteSettings.update(%{"min_password_score" => "0"}, admin_fixture())
      assert {:ok, _} = register("password1234")
    end

    test "the registration form shows the score as you type", %{conn: conn} do
      conn
      |> visit(~p"/register")
      |> fill_in("Password", with: "password1")
      |> assert_has("#password-strength", text: "Password strength: very weak")
      |> fill_in("Password", with: "correct horse battery staple violin")
      |> refute_has("#password-strength", text: "too easy to guess")
    end
  end

  describe "breached passwords" do
    setup do
      {:ok, server} =
        start_supervised({Bandit, plug: {PwnedStub, test: self()}, ip: {127, 0, 0, 1}, port: 0})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      put_config(:firefly, HTTP, allow_private: [{127, 0, 0, 1}])
      put_config(:firefly, Passwords, pwned_passwords_url: "http://127.0.0.1:#{port}/range/")
      :ok
    end

    test "are refused, sending only the hash's first 5 characters" do
      assert {:error, changeset} = register("tangerine-otter-galaxy-42")

      assert "has appeared in a data breach (haveibeenpwned.com): choose another" in errors_on(
               changeset
             ).password

      prefix = binary_part(PwnedStub.hash("tangerine-otter-galaxy-42"), 0, 5)
      assert_received {:range, ^prefix}

      assert {:ok, user} = register(@strong)

      assert {:error, _} =
               Accounts.reset_user_password(user, %{password: "tangerine-otter-galaxy-42"})
    end

    test "aren't checked when the setting is off" do
      {:ok, _} = SiteSettings.update(%{"check_breached_passwords" => "false"}, admin_fixture())
      assert {:ok, _} = register("tangerine-otter-galaxy-42")
      refute_received {:range, _}
    end

    test "fail open when the service can't be reached" do
      put_config(:firefly, Passwords, pwned_passwords_url: "http://127.0.0.1:1/range/")

      log = capture_log(fn -> assert {:ok, _} = register("tangerine-otter-galaxy-42") end)
      assert log =~ "Pwned Passwords check skipped"
    end
  end

  describe "new device emails" do
    defp log_in(conn, user, agent, ip) do
      %{conn | remote_ip: ip}
      |> put_req_header("user-agent", agent)
      |> post("/auth/identity/callback", %{
        "user" => %{"username" => user.username, "password" => @strong}
      })
    end

    @firefox "Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0"
    @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36"

    test "a login from a new browser or network is emailed; known ones aren't", %{conn: conn} do
      {:ok, user} = register(@strong)

      # The first login, then the same browser on the same network.
      log_in(conn, user, @firefox, {198, 51, 100, 7})
      log_in(build_conn(), user, @firefox, {198, 51, 100, 9})
      refute_enqueued(worker: EmailWorker, args: %{template: "new_device"})

      log_in(build_conn(), user, @chrome, {198, 51, 100, 7})
      assert [%{args: %{"session_id" => session_id}}] = all_enqueued(worker: EmailWorker)

      assert :ok =
               perform_job(EmailWorker, %{
                 template: "new_device",
                 user_id: user.id,
                 session_id: session_id
               })

      assert_email_sent(fn email ->
        assert email.subject =~ "New login to your"
        assert email.text_body =~ "Chrome on Windows, from 198.51.100.7"
        assert email.text_body =~ "/settings/security"
      end)

      log_in(build_conn(), user, @firefox, {203, 0, 113, 1})
      assert length(all_enqueued(worker: EmailWorker)) == 2
    end

    test "members can turn them off", %{conn: conn} do
      {:ok, user} = register(@strong)
      log_in(conn, user, @firefox, {198, 51, 100, 7})

      conn
      |> log_in_as(user)
      |> visit(~p"/settings/notifications")
      |> uncheck("Email me when my account is logged into from a new device")
      |> click_button("Save")

      refute Repo.reload(user).new_device_emails
      before = all_enqueued(worker: EmailWorker)
      log_in(build_conn(), user, @chrome, {203, 0, 113, 1})
      assert all_enqueued(worker: EmailWorker) == before
      assert length(UserSessions.list(%User{id: user.id})) == 3
    end
  end

  describe "login delays" do
    setup do
      put_config(:firefly, Security, max_login_delay_ms: 4_000)
      :ok
    end

    test "grow with an account's recent failures, up to the maximum", %{conn: conn} do
      {:ok, user} = register(@strong)
      fail = fn -> Security.login_failed("login.failure", user.username, %{}) end

      delays =
        for _ <- 1..8 do
          delay = Security.login_delay(user.username, {192, 0, 2, 1})
          fail.()
          delay
        end

      assert delays == [0, 0, 0, 250, 500, 1000, 2000, 4000]
      assert Security.login_delay("nobody", {192, 0, 2, 1}) == 0
      _ = conn
    end

    test "grow with an address's failures, feeding the jail" do
      put_config(:firefly, Jail, enabled: true, trusted_proxies: [])
      Jail.reset()
      on_exit(&Jail.reset/0)

      Firefly.Moderation.Akismet.put_client(%{ip: "192.0.2.50"})

      for _ <- 1..5,
          do: Security.login_failed("login.failure", "nobody#{System.unique_integer()}", %{})

      assert Jail.points("192.0.2.50", "auth") == 5
      assert Security.login_delay("someone", "192.0.2.50") == 1000
    end
  end
end
