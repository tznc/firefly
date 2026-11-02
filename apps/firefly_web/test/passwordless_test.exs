defmodule FireflyWeb.PasswordlessTest do
  use FireflyWeb.ConnCase
  use Bamboo.Test, shared: true

  import Phoenix.LiveViewTest, only: [live: 2, render_hook: 3, assert_reply: 2, render: 1]
  require Phoenix.LiveViewTest

  alias Firefly.{
    Auth,
    MagicLinks,
    Passkeys,
    Repo,
    SiteSettings,
    SoftAuthenticator,
    TwoFactor
  }

  alias Firefly.Forums.User

  defp logged_in(conn), do: get_session(conn, :current_user)

  defp setting(settings), do: {:ok, _} = SiteSettings.update(settings, admin_fixture())

  describe "passkeys" do
    defp add_passkey(conn, user, opts \\ []) do
      key = SoftAuthenticator.new(Integer.to_string(user.id))
      {:ok, view, _html} = conn |> log_in_as(user) |> live(~p"/settings/security")
      render_hook(view, "passkey_options", %{})
      assert_reply(view, %{options: options})
      assert options.authenticatorSelection.residentKey == "required"
      assert options.authenticatorSelection.userVerification == "required"

      params = Map.put(SoftAuthenticator.register(key, options, opts), "name", "Laptop")
      render_hook(view, "passkey_register", params)
      {key, view}
    end

    defp passkey_login(conn, key, opts \\ []) do
      conn = get(conn, "/login/passkey/challenge")
      options = json_response(conn, 200)
      {params, key} = SoftAuthenticator.assert(key, %{challenge: options["challenge"]}, opts)
      {post(recycle(conn), "/login/passkey", %{"passkey" => params}), key, params}
    end

    test "adding one and logging in with it alone, skipping two-factor", %{conn: conn} do
      user = user_fixture()
      {key, view} = add_passkey(conn, user)
      assert render(view) =~ "Passkey added."
      assert [%{name: "Laptop", passkey: true}] = Passkeys.list(user)
      # It isn't a second factor.
      refute TwoFactor.enabled?(user)
      assert TwoFactor.credentials(user) == []

      secret = TwoFactor.new_secret()
      {:ok, _} = TwoFactor.enable_totp(user, secret, NimbleTOTP.verification_code(secret))

      options = json_response(get(build_conn(), "/login/passkey/challenge"), 200)
      assert options["userVerification"] == "required"
      assert options["allowCredentials"] == []
      assert options["rpId"] == "localhost"

      {conn, _key, _params} = passkey_login(build_conn(), key)
      assert redirected_to(conn) == ~p"/"
      assert logged_in(conn) == user.id
    end

    test "registration and login need the user verified", %{conn: conn} do
      user = user_fixture()
      {_key, view} = add_passkey(conn, user, flags: 0x41)
      assert render(view) =~ "couldn&#39;t be added"
      assert Passkeys.list(user) == []

      {key, _view} = add_passkey(conn, user)
      {conn, _key, _params} = passkey_login(build_conn(), key, flags: 0x01)
      refute logged_in(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "That passkey wasn't accepted."
    end

    test "an answer works once, and only for its owner", %{conn: conn} do
      user = user_fixture()
      {key, _view} = add_passkey(conn, user)

      {conn, _key, params} = passkey_login(build_conn(), key)
      assert logged_in(conn)
      replay = post(recycle(conn), "/login/passkey", %{"passkey" => params})
      assert Phoenix.Flash.get(replay.assigns.flash, :error) == "That passkey wasn't accepted."

      # Another account's user handle.
      {conn, _key, _params} = passkey_login(build_conn(), %{key | user_handle: "999999"})
      refute logged_in(conn)

      # A credential nobody registered.
      {conn, _key, _params} = passkey_login(build_conn(), SoftAuthenticator.new())
      refute logged_in(conn)
    end

    test "off with the site setting", %{conn: conn} do
      user = user_fixture()
      {key, _view} = add_passkey(conn, user)
      options = json_response(get(build_conn(), "/login/passkey/challenge"), 200)
      {params, _} = SoftAuthenticator.assert(key, %{challenge: options["challenge"]})

      setting(%{"passkeys" => "false"})
      assert json_response(get(build_conn(), "/login/passkey/challenge"), 404)
      refute logged_in(post(build_conn(), "/login/passkey", %{"passkey" => params}))
      build_conn() |> visit(~p"/login") |> refute_has("#passkey-login")
    end

    test "the login pages offer them", %{conn: conn} do
      conn
      |> visit(~p"/login")
      |> assert_has("#passkey-login[phx-hook=PasskeyLogin][data-conditional=false]")

      conn
      |> visit(~p"/auth/identity")
      |> assert_has("#passkey-login[data-conditional=true]")
      |> assert_has("input[name='user[username]'][autocomplete='username webauthn']")
    end

    test "renaming, and removing all but the last way in", %{conn: conn} do
      # No password, no email: the passkey is all they have.
      {:ok, user} =
        Firefly.Forums.create_user(%{username: "solo", name: "Solo", email: nil})

      {_key, _view} = add_passkey(conn, user)
      [passkey] = Passkeys.list(user)

      session =
        conn
        |> log_in_as(user)
        |> visit(~p"/settings/security")
        |> fill_in("#rename-passkey-#{passkey.id} input", "Name", with: "Phone")
        |> click_button("#rename-passkey-#{passkey.id} button", "Rename")
        |> assert_has("#flash-info", text: "Renamed.")
        |> click_button("Remove passkey Phone")
        |> assert_has("#flash-error", text: "your only one")

      {_key, _view} = add_passkey(conn, user)

      session
      |> visit(~p"/settings/security")
      |> click_button("Remove passkey Phone")
      |> assert_has("#flash-info", text: "Passkey removed.")

      assert [%{name: "Laptop"}] = Passkeys.list(user)
    end
  end

  describe "email login links" do
    defp request_link(email, ip \\ {127, 0, 0, 1}) do
      assert :ok = MagicLinks.deliver(email, ip)
    end

    defp delivered_token do
      assert_received {:delivered_email, email}
      [_, token] = Regex.run(~r{/login/email/([A-Za-z0-9_-]+)}, email.text_body)
      {email, token}
    end

    test "log a confirmed member in, once", %{conn: conn} do
      user = user_fixture(%{email: "Grace@Example.com"})
      request_link(" grace@example.com ")
      {email, token} = delivered_token()
      assert email.to == [{nil, "Grace@Example.com"}]
      assert email.subject =~ "login link"

      # Opening the page doesn't use the link.
      conn
      |> visit(~p"/login/email/#{token}")
      |> assert_has("h1", text: "Log in as @#{user.username}")

      conn = post(conn, "/login/email/#{token}")
      assert redirected_to(conn) == ~p"/"
      assert logged_in(conn) == user.id

      conn = post(build_conn(), "/login/email/#{token}")
      refute logged_in(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired or was used"

      build_conn()
      |> visit(~p"/login/email/#{token}")
      |> assert_has("h1", text: "That link doesn't work")
    end

    test "the request form says the same either way", %{conn: conn} do
      user_fixture(%{email: "known@example.com"})

      for address <- ["known@example.com", "unknown@example.com"] do
        conn
        |> visit(~p"/login")
        |> click_link("Email me a login link")
        |> fill_in("Email", with: address)
        |> click_button("Email me a link")
        |> assert_has("#flash-info", text: "If that address can log in here")
      end

      assert_received {:delivered_email, %{to: [{nil, "known@example.com"}]}}
      refute_received {:delivered_email, _}
    end

    test "never go to unconfirmed addresses", %{conn: _conn} do
      {:ok, _} =
        Firefly.Forums.register_user(%{
          username: "unconfirmed",
          email: "new@example.com",
          password: "a long password"
        })

      request_link("new@example.com")
      refute_received {:delivered_email, _}
    end

    test "expire after 15 minutes", %{conn: conn} do
      user_fixture(%{email: "late@example.com"})
      request_link("late@example.com")
      {_email, token} = delivered_token()
      Repo.update_all("magic_link_tokens", set: [expires_at: ~U[2020-01-01 00:00:00Z]])
      refute logged_in(post(conn, "/login/email/#{token}"))
    end

    test "still ask for the second factor", %{conn: conn} do
      user = user_fixture(%{email: "2fa@example.com"})
      secret = TwoFactor.new_secret()
      {:ok, _} = TwoFactor.enable_totp(user, secret, NimbleTOTP.verification_code(secret))
      request_link("2fa@example.com")
      {_email, token} = delivered_token()

      conn = post(conn, "/login/email/#{token}")
      assert redirected_to(conn) == ~p"/login/two-factor"
      refute logged_in(conn)
    end

    test "sign up a new address only when the site allows it", %{conn: conn} do
      request_link("newbie@example.com")
      refute_received {:delivered_email, _}

      setting(%{"magic_link_signup" => "true"})
      request_link("newbie@example.com")
      {email, token} = delivered_token()
      assert email.text_body =~ "create your account"

      conn |> visit(~p"/login/email/#{token}") |> assert_has("h1", text: "Create your account")
      conn = post(conn, "/login/email/#{token}")
      user = Repo.get!(User, logged_in(conn))
      assert user.username == "newbie"
      assert user.email == "newbie@example.com"
      assert User.confirmed?(user)

      setting(%{"allow_registrations" => "false"})
      request_link("another@example.com")
      refute_received {:delivered_email, _}
    end

    test "are rate limited per address and IP" do
      original = Application.get_env(:firefly, Firefly.RateLimit)

      Application.put_env(:firefly, Firefly.RateLimit,
        limits: Keyword.put(original[:limits], :magic_link, {1, 60_000})
      )

      on_exit(fn -> Application.put_env(:firefly, Firefly.RateLimit, original) end)

      assert :ok = MagicLinks.deliver("a@example.com", {10, 0, 0, 1})
      assert {:error, :rate_limited} = MagicLinks.deliver("a@example.com", {10, 0, 0, 2})
      assert {:error, :rate_limited} = MagicLinks.deliver("b@example.com", {10, 0, 0, 1})
    end

    test "off with the site setting, or when SSO is the only way in", %{conn: conn} do
      setting(%{"magic_links" => "false"})
      assert {:error, :disabled} = MagicLinks.deliver("a@example.com", {10, 0, 0, 1})
      conn |> visit(~p"/login/email") |> assert_path(~p"/login")
      conn |> visit(~p"/login") |> refute_has("a", text: "Email me a login link")
    end

    test "count as a way in for members with a confirmed email" do
      {:ok, user} =
        Auth.login(%{
          provider: :github,
          uid: 5,
          nickname: "octo",
          email: "o@example.com",
          email_verified: true
        })

      assert :ok = Auth.disconnect(user, "github")
    end
  end
end
