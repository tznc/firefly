defmodule FireflyWeb.AuthTest do
  use FireflyWeb.ConnCase

  alias Firefly.{Accounts, Repo}
  alias Firefly.Accounts.Auth
  alias Firefly.Accounts.{User, UserIdentity}

  @github %{
    provider: :github,
    uid: 1001,
    name: "Josh Adams",
    nickname: "knewter",
    email: "josh@example.com",
    email_verified: true
  }

  defp callback(conn, auth) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> fetch_flash()
    |> assign(:ueberauth_auth, auth)
    |> FireflyWeb.AuthController.callback(%{})
  end

  describe "login/1 with GitHub" do
    test "creates a user linked to the GitHub account id" do
      assert {:ok, user} = Auth.login(@github)
      assert user.email == "josh@example.com"
      assert user.username == "knewter"
      assert User.confirmed?(user)

      assert %{"github" => %{uid: "1001", info: %{"nickname" => "knewter"}}} =
               Auth.identities(user)
    end

    test "fills in a missing name and email" do
      assert {:ok, user} = Auth.login(%{@github | name: nil, email: nil})
      assert user.name == "knewter"
      assert user.email == "knewter@users.noreply.github.com"
    end

    test "logs the same account into the same user, even after a rename" do
      {:ok, %{id: id}} = Auth.login(@github)
      assert {:ok, %{id: ^id}} = Auth.login(@github)
      assert {:ok, %{id: ^id}} = Auth.login(%{@github | nickname: "renamed"})
    end

    test "never logs into a password account with the same username" do
      {:ok, victim} =
        Accounts.register_user(%{
          username: "knewter",
          email: "someone@example.com",
          password: "s3cret-password"
        })

      assert {:ok, attacker} = Auth.login(@github)
      refute attacker.id == victim.id
      assert attacker.username == "knewter-1"
    end

    test "never logs a different account into an existing user" do
      {:ok, first} = Auth.login(@github)

      # Emails are unique: one with the same address gets no account.
      assert {:error, changeset} = Auth.login(%{@github | uid: 2002, email: "JOSH@example.com"})
      assert {"has already been taken", _} = changeset.errors[:email]

      assert {:ok, other} = Auth.login(%{@github | uid: 2002, email: "other@example.com"})
      refute other.id == first.id
    end

    test "links a pre-existing GitHub-created account only when the email matches" do
      {:ok, legacy} =
        Accounts.create_user(%{username: "knewter", name: "Josh", email: "josh@example.com"})

      assert {:ok, %{id: id}} = Auth.login(@github)
      assert id == legacy.id

      {:ok, other_legacy} =
        Accounts.create_user(%{username: "octo", name: "Octo", email: "octo@example.com"})

      assert {:ok, impostor} =
               Auth.login(%{@github | uid: 3003, nickname: "octo", email: "x@example.com"})

      refute impostor.id == other_legacy.id
    end

    test "requires an account id" do
      assert {:error, "GitHub did not return an account id."} =
               Auth.login(Map.delete(@github, :uid))
    end
  end

  describe "other providers" do
    test "Google: verified emails are confirmed, names come from the email" do
      auth = %Ueberauth.Auth{
        provider: :google,
        uid: "g-1",
        info: %Ueberauth.Auth.Info{name: "Ada Lovelace", email: "ada.l@example.com"},
        extra: %Ueberauth.Auth.Extra{raw_info: %{user: %{"email_verified" => true}}}
      }

      assert {:ok, user} = Auth.login(Auth.from_ueberauth(auth))
      assert user.username == "adal"
      assert user.name == "Ada Lovelace"
      assert User.confirmed?(user)
    end

    test "Discord: an unverified email isn't confirmed" do
      auth = %Ueberauth.Auth{
        provider: :discord,
        uid: "d-1",
        info: %Ueberauth.Auth.Info{nickname: "wumpus", email: "w@example.com"},
        extra: %Ueberauth.Auth.Extra{raw_info: %{user: %{"verified" => false}}}
      }

      assert {:ok, user} = Auth.login(Auth.from_ueberauth(auth))
      assert user.username == "wumpus"
      refute User.confirmed?(user)
    end

    test "X and Apple give no email; names come from first and last name" do
      x = %Ueberauth.Auth{provider: :x, uid: "x-1", info: %Ueberauth.Auth.Info{nickname: "jack"}}
      assert {:ok, %{username: "jack", email: nil}} = Auth.login(Auth.from_ueberauth(x))

      apple = %Ueberauth.Auth{
        provider: :apple,
        uid: "a-1",
        info: %Ueberauth.Auth.Info{first_name: "Tim", last_name: "Apple"}
      }

      assert {:ok, %{username: "TimApple", name: "Tim Apple"}} =
               Auth.login(Auth.from_ueberauth(apple))
    end

    test "registration closed: no new accounts" do
      admin = admin_fixture()
      {:ok, _} = Firefly.SiteSettings.update(%{"allow_registrations" => "false"}, admin)

      assert {:error, "New registrations are closed."} =
               Auth.login(%{provider: :slack, uid: "T1/U1", name: "Sam"})
    end
  end

  describe "connecting and disconnecting" do
    test "a logged-in callback connects the account", %{conn: conn} do
      user = user_fixture()

      auth = %Ueberauth.Auth{
        provider: :google,
        uid: "g-2",
        info: %Ueberauth.Auth.Info{email: "me@example.com"}
      }

      conn = conn |> assign(:current_user, user) |> callback(auth)
      assert redirected_to(conn) == ~p"/settings/logins"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Google account connected."
      assert {:ok, %{id: id}} = Auth.login(%{provider: :google, uid: "g-2"})
      assert id == user.id

      # Someone else can't take it.
      other = user_fixture()
      conn = build_conn() |> assign(:current_user, other) |> callback(auth)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That Google account is linked to another account."
    end

    test "the last way to log in can't be disconnected", %{conn: conn} do
      # Email login links would be another way in (see Firefly.Accounts.MagicLinks).
      {:ok, _} = Firefly.SiteSettings.update(%{"magic_links" => "false"}, admin_fixture())
      {:ok, user} = Auth.login(@github)

      assert {:error, "Connect another account first: this is your only way to log in."} =
               Auth.disconnect(user, "github")

      {:ok, _} = Auth.connect(user, %{provider: :discord, uid: "d-9", nickname: "me"})

      conn
      |> log_in_as(user)
      |> visit(~p"/settings/logins")
      |> assert_has("#login-discord", text: "Connected as me")
      |> assert_has("#login-google a", text: "Connect")
      |> click_button("Disconnect GitHub")
      |> assert_has("#flash-info", text: "GitHub account disconnected.")
      |> click_button("Disconnect Discord")
      |> assert_has("#flash-error", text: "your only way to log in")

      assert [%UserIdentity{provider: "discord"}] = Repo.all(UserIdentity)
    end
  end

  describe "enabled providers" do
    setup do
      original = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
      Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, client_id: nil)

      on_exit(fn ->
        Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, original)
      end)
    end

    test "only enabled providers get a button and a route", %{conn: conn} do
      refute Auth.enabled?(:google)
      assert Auth.enabled?(:github)

      conn
      |> visit(~p"/login")
      |> assert_has("#login-github", text: "Log in with GitHub")
      |> assert_has("#login-slack", text: "Log in with Slack")
      |> refute_has("#login-google")

      conn
      |> visit("/auth/google")
      |> assert_path(~p"/login")
      |> assert_has("#flash-error", text: "Google login isn't enabled.")

      assert redirected_to(get(conn, "/auth/github")) =~
               "https://github.com/login/oauth/authorize"
    end
  end

  describe "in-house strategies" do
    test "X redirects with PKCE and keeps the verifier in a signed cookie", %{conn: conn} do
      conn = get(conn, "/auth/x")
      location = redirected_to(conn)
      assert location =~ "https://x.com/i/oauth2/authorize"
      query = URI.decode_query(URI.parse(location).query)
      assert query["code_challenge_method"] == "S256"
      assert query["client_id"] == "test-client"
      assert query["state"]
      assert conn.resp_cookies["firefly_oauth_pkce"]
    end

    test "Slack redirects to its OpenID Connect authorization", %{conn: conn} do
      location = conn |> get("/auth/slack") |> redirected_to()
      assert location =~ "https://slack.com/openid/connect/authorize"
      assert URI.decode_query(URI.parse(location).query)["scope"] == "openid profile email"
    end
  end
end
