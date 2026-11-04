defmodule FireflyWeb.TwoFactorTest do
  use FireflyWeb.ConnCase

  import Phoenix.LiveViewTest, only: [live: 2, render_hook: 3, render_click: 2, assert_reply: 2]
  require Phoenix.LiveViewTest

  alias Firefly.{Repo, SiteSettings, SoftAuthenticator}
  alias Firefly.Accounts.{Auth, TwoFactor, WebAuthn}
  alias Firefly.Accounts.User
  alias Firefly.Moderation.StaffAction

  @password "correct horse battery"

  defp password_user do
    {:ok, user} =
      Firefly.Accounts.register_user(%{
        username: "ada#{System.unique_integer([:positive])}",
        email: "ada@example.com",
        password: @password
      })

    user
  end

  defp with_totp(user) do
    secret = TwoFactor.new_secret()
    code = NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30)
    {:ok, codes} = TwoFactor.enable_totp(user, secret, code)
    {secret, codes}
  end

  defp password_login(conn, user, password \\ @password) do
    post(conn, "/auth/identity/callback", %{
      "user" => %{"username" => user.username, "password" => password}
    })
  end

  defp logged_in(conn), do: get_session(conn, :current_user)

  describe "logging in" do
    test "a password login waits for the second factor", %{conn: conn} do
      user = password_user()
      {secret, _codes} = with_totp(user)

      conn = password_login(conn, user)
      assert redirected_to(conn) == ~p"/login/two-factor"
      refute logged_in(conn)

      # Nothing else is open meanwhile.
      conn = recycle(conn)

      conn
      |> visit(~p"/login/two-factor")
      |> assert_has("label", text: "Authenticator or backup code")

      conn = post(recycle(conn), "/login/two-factor", %{"code" => "000000"})
      assert redirected_to(conn) == ~p"/login/two-factor"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't right"
      refute logged_in(conn)

      code = NimbleTOTP.verification_code(secret)
      conn = post(recycle(conn), "/login/two-factor", %{"code" => code})
      assert redirected_to(conn) == ~p"/"
      assert logged_in(conn) == user.id
      refute get_session(conn, :two_factor)

      # The same code doesn't work twice.
      conn = build_conn() |> password_login(user) |> recycle()
      conn = post(conn, "/login/two-factor", %{"code" => code})
      refute logged_in(conn)
    end

    test "a backup code works once", %{conn: conn} do
      user = password_user()
      {_secret, [code | _] = codes} = with_totp(user)
      assert length(codes) == 10
      assert code =~ ~r/^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$/

      conn = conn |> password_login(user) |> recycle()
      conn = post(conn, "/login/two-factor", %{"code" => String.upcase(code)})
      assert logged_in(conn) == user.id
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "You used a backup code: 9 left."

      conn = build_conn() |> password_login(user) |> recycle()
      refute logged_in(post(conn, "/login/two-factor", %{"code" => code}))
    end

    test "a waiting login expires", %{conn: conn} do
      user = password_user()
      with_totp(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{
          two_factor: %{"user_id" => user.id, "at" => System.system_time(:second) - 601}
        })
        |> post("/login/two-factor", %{"code" => "123456"})

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "timed out"
    end

    test "attempts are rate limited", %{conn: conn} do
      original = Application.get_env(:firefly, Firefly.RateLimit)

      Application.put_env(:firefly, Firefly.RateLimit,
        limits: Keyword.put(original[:limits], :two_factor, {2, 60_000})
      )

      on_exit(fn -> Application.put_env(:firefly, Firefly.RateLimit, original) end)

      user = password_user()
      {secret, _codes} = with_totp(user)
      conn = conn |> password_login(user) |> recycle()

      conn = post(conn, "/login/two-factor", %{"code" => "111111"})
      conn = post(recycle(conn), "/login/two-factor", %{"code" => "222222"})

      conn =
        post(recycle(conn), "/login/two-factor", %{"code" => NimbleTOTP.verification_code(secret)})

      refute logged_in(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "too often"
    end

    test "social logins ask too, unless the site says otherwise" do
      {:ok, user} = Auth.login(%{provider: :github, uid: 7, nickname: "octo"})
      with_totp(user)

      auth = %Ueberauth.Auth{
        provider: :github,
        uid: 7,
        info: %Ueberauth.Auth.Info{nickname: "octo"}
      }

      social = fn ->
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> fetch_flash()
        |> assign(:ueberauth_auth, auth)
        |> FireflyWeb.AuthController.callback(%{})
      end

      assert redirected_to(social.()) == ~p"/login/two-factor"

      {:ok, _} = SiteSettings.update(%{"two_factor_sso_logins" => "false"}, admin_fixture())
      conn = social.()
      assert redirected_to(conn) == ~p"/"
      assert logged_in(conn) == user.id
      _ = conn
    end

    test "the API asks for a code", %{conn: conn} do
      user = password_user()
      {secret, _codes} = with_totp(user)
      params = %{"username" => user.username, "password" => @password}

      conn = post(conn, "/api/v1/auth/identity", %{"user" => params})
      assert %{"two_factor" => true} = json_response(conn, 401)

      conn =
        post(build_conn(), "/api/v1/auth/identity", %{
          "user" => Map.put(params, "otp", NimbleTOTP.verification_code(secret))
        })

      assert %{"data" => %{"api_token" => _}} = json_response(conn, 200)
    end
  end

  describe "settings" do
    test "setting up an authenticator app and turning it off", %{conn: conn} do
      user = password_user()

      session =
        conn
        |> log_in_as(user)
        |> visit(~p"/settings/security")
        |> assert_has("#security", text: "is off")
        |> click_button("Set up an authenticator app")
        |> assert_has("#totp-qr svg")

      secret =
        session
        |> Map.fetch!(:view)
        |> Phoenix.LiveViewTest.render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#totp-secret")
        |> LazyHTML.text()
        |> String.replace(" ", "")
        |> Base.decode32!(padding: false)

      session
      |> fill_in("Code", with: "000000")
      |> click_button("Turn on")
      |> assert_has("#flash-error", text: "isn't right")
      |> fill_in("Code", with: NimbleTOTP.verification_code(secret))
      |> click_button("Turn on")
      |> assert_has("#flash-info", text: "Two-factor authentication is on.")
      |> assert_has("#new-backup-codes li", count: 10)
      |> assert_has("#backup-codes-left", text: "10 unused")
      |> fill_in("#disable-totp-form input", "Your password or a current code", with: "wrong")
      |> click_button("Remove authenticator app")
      |> assert_has("#flash-error", text: "isn't right")
      |> fill_in("#disable-totp-form input", "Your password or a current code", with: @password)
      |> click_button("Remove authenticator app")
      |> assert_has("#flash-info", text: "Authenticator app removed.")

      refute TwoFactor.enabled?(user)
      assert TwoFactor.backup_codes_left(user) == 0
    end

    test "regenerating backup codes voids the old ones", %{conn: conn} do
      user = password_user()
      {_secret, [old | _]} = with_totp(user)

      conn
      |> log_in_as(user)
      |> visit(~p"/settings/security")
      |> click_button("Generate new backup codes")
      |> assert_has("#new-backup-codes li", count: 10)

      assert {:error, :invalid_code} = TwoFactor.verify_code(user, old)
    end
  end

  describe "security keys" do
    defp add_key(conn, user, name \\ "YubiKey") do
      key = SoftAuthenticator.new()
      {:ok, view, _html} = conn |> log_in_as(user) |> live(~p"/settings/security")
      render_hook(view, "security_key_options", %{})
      assert_reply(view, %{options: options})
      assert options.user.name == user.username

      render_hook(
        view,
        "security_key_register",
        Map.put(SoftAuthenticator.register(key, options), "name", name)
      )

      {key, view}
    end

    defp key_login(conn, user, key, opts \\ []) do
      conn = password_login(conn, user)
      options = %{challenge: get_session(conn, :two_factor_challenge)["bytes"]}
      {params, key} = SoftAuthenticator.assert(key, options, opts)
      {post(recycle(conn), "/login/two-factor/key", %{"key" => params}), key}
    end

    test "registering one and logging in with it", %{conn: conn} do
      user = password_user()
      {key, view} = add_key(conn, user)
      assert Phoenix.LiveViewTest.render(view) =~ "Security key added."
      assert [%{name: "YubiKey", sign_count: 0}] = TwoFactor.credentials(user)
      assert TwoFactor.enabled?(user)
      assert TwoFactor.backup_codes_left(user) == 10

      build_conn()
      |> password_login(user)
      |> recycle()
      |> visit(~p"/login/two-factor")
      |> assert_has("#use-security-key[data-options]")

      {conn, key} = key_login(build_conn(), user, key)
      assert logged_in(conn) == user.id
      assert [%{sign_count: 1, last_used_at: %DateTime{}}] = TwoFactor.credentials(user)

      # A clone (its counter behind) is refused.
      {conn, _} = key_login(build_conn(), user, key, count: 1)
      refute logged_in(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "wasn't accepted"
    end

    test "answers for another site, challenge or key are refused", %{conn: conn} do
      user = password_user()
      {key, _view} = add_key(conn, user)

      for opts <- [
            [origin: "https://evil.example"],
            [rp_id: "evil.example"],
            [type: "webauthn.create"],
            [flags: 0x00]
          ] do
        {conn, _} = key_login(build_conn(), user, key, opts)
        refute logged_in(conn), "accepted #{inspect(opts)}"
      end

      {conn, _} = key_login(build_conn(), user, SoftAuthenticator.new())
      refute logged_in(conn)

      # An answer to an old challenge.
      conn = build_conn() |> password_login(user) |> recycle()
      {params, _} = SoftAuthenticator.assert(key, %{challenge: WebAuthn.encode("old challenge")})
      refute logged_in(post(conn, "/login/two-factor/key", %{"key" => params}))
    end

    test "renaming and removing one", %{conn: conn} do
      user = password_user()
      {_key, _view} = add_key(conn, user)
      [credential] = TwoFactor.credentials(user)

      conn
      |> log_in_as(user)
      |> visit(~p"/settings/security")
      |> fill_in("#rename-key-#{credential.id} input", "Name", with: "Blue key")
      |> click_button("#rename-key-#{credential.id} button", "Rename")
      |> assert_has("#flash-info", text: "Renamed.")
      |> fill_in("#delete-key-#{credential.id} input", "Your password or a current code",
        with: @password
      )
      |> click_button("Remove Blue key")
      |> assert_has("#flash-info", text: "Security key removed.")

      refute TwoFactor.enabled?(user)
    end
  end

  describe "staff" do
    test "admins reset a member's two-factor, logged", %{conn: conn} do
      admin = admin_fixture()
      user = password_user()
      with_totp(user)

      {:ok, view, _html} = conn |> log_in_as(admin) |> live(~p"/users/#{user}")
      assert render_click(view, "reset_two_factor") =~ "two-factor authentication was reset"
      refute TwoFactor.enabled?(user)
      assert Repo.get_by(StaffAction, action: "user.reset_two_factor", target_id: user.id)
    end

    test "staff must set it up when the site requires it", %{conn: conn} do
      admin = admin_fixture()
      {:ok, _} = SiteSettings.update(%{"enforce_two_factor_staff" => "true"}, admin)

      conn
      |> log_in_as(admin)
      |> visit(~p"/")
      |> assert_path(~p"/settings/security")
      |> assert_has("#flash-error", text: "Set up two-factor authentication")

      assert redirected_to(get(log_in_as(build_conn(), admin), "/staff/reports/signups/export")) ==
               "/settings/security"

      # Members aren't asked.
      build_conn() |> log_in_as(user_fixture()) |> visit(~p"/") |> assert_path(~p"/")

      with_totp(admin)
      build_conn() |> log_in_as(admin) |> visit(~p"/") |> assert_path(~p"/")
    end
  end

  test "export and deletion", %{conn: _conn} do
    user = password_user()
    with_totp(user)
    assert %{authenticator_app: true, backup_codes_left: 10} = TwoFactor.export(user)

    {:ok, _} = Firefly.Accounts.AccountDeletion.delete_account(user, @password)
    refute TwoFactor.enabled?(Repo.get!(User, user.id))
    assert TwoFactor.backup_codes_left(user) == 0
  end
end
