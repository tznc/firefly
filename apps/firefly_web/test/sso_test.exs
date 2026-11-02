defmodule FireflyWeb.SSOTest do
  use FireflyWeb.ConnCase

  import Ecto.Query

  alias Firefly.{Auth, Repo, SiteSettings}
  alias FireflyWeb.FakeOIDC
  alias Firefly.Auth.DiscourseConnect
  alias Firefly.Forums.{Role, User, UserIdentity}

  defp put_config(key, config) do
    original = Application.get_env(:firefly, key)
    Application.put_env(:firefly, key, config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:firefly, key, original),
        else: Application.delete_env(:firefly, key)
    end)
  end

  defp logged_in_user(conn) do
    case get_session(conn, :current_user) do
      nil -> nil
      id -> Repo.get(User, id)
    end
  end

  describe "OpenID Connect" do
    setup do
      idp = FakeOIDC.start()

      put_config(Firefly.Auth.OIDC,
        discovery_url: idp.discovery,
        client_id: FakeOIDC.client_id(),
        client_secret: "oidc-secret",
        name: "Corp SSO"
      )

      %{idp: idp}
    end

    # The browser's round trip: our redirect to the provider, then its
    # redirect back with a code for an ID token with `claims`.
    defp oidc_login(conn, idp, claims \\ %{}, opts \\ []) do
      conn = get(conn, "/auth/oidc")
      params = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      code = FakeOIDC.code(idp, params, claims, opts)
      state = Keyword.get(opts, :state, params["state"])
      {get(recycle(conn), "/auth/oidc/callback", %{"code" => code, "state" => state}), params}
    end

    test "redirects with state, nonce and a PKCE challenge", %{conn: conn, idp: idp} do
      conn = get(conn, "/auth/oidc")
      location = URI.parse(redirected_to(conn))

      assert "#{location.scheme}://#{location.authority}#{location.path}" ==
               idp.issuer <> "/authorize"

      query = URI.decode_query(location.query)
      assert query["client_id"] == FakeOIDC.client_id()
      assert query["scope"] == "openid email profile"
      assert query["code_challenge_method"] == "S256"
      assert query["state"] && query["nonce"]
      assert conn.resp_cookies["firefly_oidc"]
    end

    test "logs in, creating a user linked by the subject", %{conn: conn, idp: idp} do
      {conn, _params} = oidc_login(conn, idp)
      assert redirected_to(conn) == ~p"/"
      user = logged_in_user(conn)
      assert user.username == "ada"
      assert user.email == "ada@corp.example"
      assert User.confirmed?(user)
      assert %{"oidc" => %{uid: "user-1"}} = Auth.identities(user)

      # The same subject logs into the same user.
      {conn, _params} = oidc_login(build_conn(), idp, %{"preferred_username" => "renamed"})
      assert logged_in_user(conn).id == user.id
    end

    test "an unverified email isn't confirmed", %{conn: conn, idp: idp} do
      {conn, _params} = oidc_login(conn, idp, %{"sub" => "user-2", "email_verified" => false})
      refute User.confirmed?(logged_in_user(conn))
    end

    test "rejects tokens signed by another key", %{conn: conn, idp: idp} do
      forger = FakeOIDC.new_key("key-1")
      {conn, _} = oidc_login(conn, idp, %{}, sign: &FakeOIDC.sign(forger, &1))
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Failed to authenticate."
      refute logged_in_user(conn)
      assert Repo.all(UserIdentity) == []
    end

    test "rejects a tampered payload", %{conn: conn, idp: idp} do
      tamper = fn claims ->
        [header, _payload, signature] =
          String.split(FakeOIDC.sign(Agent.get(idp.agent, & &1.signing_key), claims), ".")

        payload = Base.url_encode64(Jason.encode!(%{claims | "sub" => "admin"}), padding: false)
        Enum.join([header, payload, signature], ".")
      end

      {conn, _} = oidc_login(conn, idp, %{}, sign: tamper)
      refute logged_in_user(conn)
    end

    test "rejects unsigned and shared-secret tokens", %{conn: conn, idp: idp} do
      none = fn claims ->
        header = Base.url_encode64(~s({"alg":"none"}), padding: false)
        payload = Base.url_encode64(Jason.encode!(claims), padding: false)
        header <> "." <> payload <> "."
      end

      hs256 = fn claims ->
        FakeOIDC.sign(JOSE.JWK.from_oct("oidc-secret") |> merge_kid(), claims, "HS256")
      end

      for sign <- [none, hs256] do
        {conn, _} = oidc_login(conn, idp, %{}, sign: sign)
        refute logged_in_user(conn)
      end
    end

    test "checks the issuer, audience, expiry and nonce", %{conn: conn, idp: idp} do
      now = System.system_time(:second)

      for claims <- [
            %{"iss" => "https://evil.example"},
            %{"aud" => "someone-else"},
            %{"aud" => [FakeOIDC.client_id(), "other"]},
            %{"exp" => now - 3600},
            %{"nonce" => "replayed-nonce"},
            %{"sub" => nil}
          ] do
        {conn, _} = oidc_login(conn, idp, claims)
        refute logged_in_user(conn), "accepted #{inspect(claims)}"
      end

      {conn, _} =
        oidc_login(conn, idp, %{
          "aud" => [FakeOIDC.client_id(), "other"],
          "azp" => FakeOIDC.client_id()
        })

      assert logged_in_user(conn)
    end

    test "rejects a callback with another state", %{conn: conn, idp: idp} do
      {conn, _} = oidc_login(conn, idp, %{}, state: "forged")
      refute logged_in_user(conn)
    end

    test "rejects a code redeemed without this login's PKCE verifier", %{conn: conn, idp: idp} do
      # Another browser's login: its code, with our cookies.
      {_other, params} = oidc_login(build_conn(), idp)
      code = FakeOIDC.code(idp, params)
      conn = get(conn, "/auth/oidc")
      state = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      conn =
        get(recycle(conn), "/auth/oidc/callback", %{"code" => code, "state" => state["state"]})

      refute logged_in_user(conn)
    end

    test "fetches the keys again when the provider rotates them", %{conn: conn, idp: idp} do
      {conn, _} = oidc_login(conn, idp)
      assert logged_in_user(conn)

      new_key = FakeOIDC.new_key("key-2")
      FakeOIDC.rotate(idp, [new_key], new_key)

      # The cached keys are under a minute old: not fetched again yet.
      {conn, _} = oidc_login(build_conn(), idp)
      refute logged_in_user(conn)

      :persistent_term.erase({Firefly.Auth.OIDC, {:jwks, idp.issuer <> "/jwks"}})
      {conn, _} = oidc_login(build_conn(), idp)
      assert logged_in_user(conn)
    end

    test "respects closed registrations", %{conn: conn, idp: idp} do
      {:ok, _} = SiteSettings.update(%{"allow_registrations" => "false"}, admin_fixture())
      {conn, _} = oidc_login(conn, idp)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "New registrations are closed."
    end

    test "an unreachable provider sends the browser back to the login page", %{conn: conn} do
      put_config(Firefly.Auth.OIDC,
        discovery_url: "http://127.0.0.1:1/.well-known/openid-configuration",
        client_id: "x"
      )

      conn = get(conn, "/auth/oidc")
      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "can't be reached"
    end

    test "the login page offers it by its name", %{conn: conn} do
      conn |> visit(~p"/login") |> assert_has("#login-oidc", text: "Log in with Corp SSO")
    end
  end

  describe "SSO only" do
    setup do
      put_config(Firefly.Auth.DiscourseConnect,
        url: "https://id.example/sso",
        secret: "dc-secret-123"
      )

      put_config(Firefly.Auth, sso_only: true)
    end

    test "hides and refuses every other way in", %{conn: conn} do
      assert Auth.sso_only?()
      assert Auth.enabled_providers() == [:discourse_connect]

      conn
      |> visit(~p"/login")
      |> assert_has("#login-discourse_connect", text: "Log in with DiscourseConnect")
      |> refute_has("#login-github")
      |> refute_has("a", text: "Create Account")
      |> refute_has("a", text: "Sign In")

      for path <- [~p"/auth/identity", ~p"/register", ~p"/reset-password"] do
        conn |> visit(path) |> assert_path(~p"/login")
      end

      conn = post(build_conn(), "/auth/identity/callback", %{"user" => %{"username" => "a"}})
      assert redirected_to(conn) == ~p"/login"
      assert redirected_to(get(build_conn(), "/auth/github")) == ~p"/login"

      conn = post(build_conn(), "/api/v1/auth/identity", %{"user" => %{"username" => "a"}})
      assert json_response(conn, 403)
    end

    test "a password no longer counts as another way in", %{conn: conn} do
      _ = conn
      user = user_fixture()

      user =
        user |> Ecto.Changeset.change(password_hash: Bcrypt.hash_pwd_salt("pw")) |> Repo.update!()

      {:ok, _} = Auth.connect(user, %{provider: :discourse_connect, uid: "9"})

      assert {:error, "Connect another account first" <> _} =
               Auth.disconnect(user, "discourse_connect")
    end

    test "is off while no SSO provider is enabled" do
      put_config(Firefly.Auth.DiscourseConnect, [])
      refute Auth.sso_only?()
      assert Auth.password_login?()
    end
  end

  describe "DiscourseConnect" do
    setup do
      put_config(Firefly.Auth.DiscourseConnect,
        url: "https://id.example/session/sso_provider",
        secret: "dc-secret-123",
        name: "Example ID"
      )

      :ok
    end

    # Our redirect to the provider: returns the conn and the decoded payload.
    defp dc_start(conn) do
      conn = get(conn, "/auth/discourse_connect")
      location = URI.parse(redirected_to(conn))
      query = URI.decode_query(location.query)
      assert query["sig"] == DiscourseConnect.sign(query["sso"])
      {conn, query["sso"] |> Base.decode64!() |> URI.decode_query()}
    end

    defp dc_answer(fields) do
      sso = Base.encode64(URI.encode_query(fields))
      %{"sso" => sso, "sig" => DiscourseConnect.sign(sso)}
    end

    defp dc_login(conn, fields) do
      {conn, request} = dc_start(conn)
      answer = dc_answer(Map.put(fields, "nonce", request["nonce"]))
      get(recycle(conn), "/auth/discourse_connect/callback", answer)
    end

    @fields %{
      "external_id" => "42",
      "email" => "grace@example.com",
      "username" => "grace",
      "name" => "Grace Hopper"
    }

    test "sends a signed nonce and return URL", %{conn: conn} do
      {conn, request} = dc_start(conn)
      assert redirected_to(conn) =~ "https://id.example/session/sso_provider?"
      assert request["return_sso_url"] == "http://localhost:4002/auth/discourse_connect/callback"
      assert get_session(conn, :discourse_connect_nonce) == request["nonce"]
    end

    test "logs in, creating a user linked by external_id", %{conn: conn} do
      conn = dc_login(conn, @fields)
      assert redirected_to(conn) == ~p"/"
      user = logged_in_user(conn)
      assert %{username: "grace", name: "Grace Hopper", email: "grace@example.com"} = user
      assert User.confirmed?(user)
      assert %{"discourse_connect" => %{uid: "42"}} = Auth.identities(user)

      conn = dc_login(build_conn(), %{@fields | "username" => "gracie"})
      assert logged_in_user(conn).id == user.id
      # Not synced: the setting is off.
      assert logged_in_user(conn).username == "grace"
    end

    test "require_activation leaves the email unconfirmed", %{conn: conn} do
      conn = dc_login(conn, Map.put(@fields, "require_activation", "true"))
      refute User.confirmed?(logged_in_user(conn))
    end

    test "links the account with the vouched-for, confirmed email", %{conn: conn} do
      existing = user_fixture(%{email: "Grace@example.com"})
      conn = dc_login(conn, @fields)
      assert logged_in_user(conn).id == existing.id

      # Not when the provider asks for activation.
      other = user_fixture(%{email: "linus@example.com"})

      conn =
        dc_login(build_conn(), %{
          "external_id" => "43",
          "email" => "linus@example.com",
          "username" => "linus",
          "require_activation" => "true"
        })

      refute logged_in_user(conn).id == other.id
    end

    test "rejects a tampered payload or signature", %{conn: conn} do
      {conn, request} = dc_start(conn)
      answer = dc_answer(Map.put(@fields, "nonce", request["nonce"]))

      forged =
        Base.encode64(
          URI.encode_query(
            Map.put(@fields, "nonce", request["nonce"])
            |> Map.put("admin", "true")
          )
        )

      for params <- [
            %{answer | "sso" => forged},
            %{answer | "sig" => String.duplicate("0", 64)},
            %{answer | "sig" => "short"},
            Map.delete(answer, "sig")
          ] do
        conn = get(recycle(conn), "/auth/discourse_connect/callback", params)

        assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                 "Example ID login failed. Try again."

        refute logged_in_user(conn)
      end

      assert Repo.all(User) == []
    end

    test "a nonce works once", %{conn: conn} do
      {conn, request} = dc_start(conn)
      answer = dc_answer(Map.put(@fields, "nonce", request["nonce"]))
      started = recycle(conn)

      assert logged_in_user(get(started, "/auth/discourse_connect/callback", answer))

      # Replayed, even with the original session.
      replay = get(started, "/auth/discourse_connect/callback", answer)
      refute logged_in_user(replay)
      assert Phoenix.Flash.get(replay.assigns.flash, :error) =~ "expired or was used already"
    end

    test "a nonce belongs to the browser that started the login", %{conn: conn} do
      {_conn, request} = dc_start(conn)
      answer = dc_answer(Map.put(@fields, "nonce", request["nonce"]))

      {other, _} = dc_start(build_conn())
      conn = get(recycle(other), "/auth/discourse_connect/callback", answer)
      refute logged_in_user(conn)

      conn = get(build_conn(), "/auth/discourse_connect/callback", answer)
      refute logged_in_user(conn)
    end

    test "an expired nonce is refused", %{conn: conn} do
      {conn, request} = dc_start(conn)
      Repo.update_all("discourse_connect_nonces", set: [expires_at: ~U[2020-01-01 00:00:00Z]])
      answer = dc_answer(Map.put(@fields, "nonce", request["nonce"]))
      conn = get(recycle(conn), "/auth/discourse_connect/callback", answer)
      refute logged_in_user(conn)
    end

    test "requires an external_id" do
      {nonce, _url} = DiscourseConnect.request("http://localhost/callback")
      answer = dc_answer(%{"nonce" => nonce, "email" => "x@example.com"})

      assert {:error, :no_external_id} =
               DiscourseConnect.verify(answer["sso"], answer["sig"], nonce)
    end

    test "syncs the fields the site settings allow", %{conn: conn} do
      admin = admin_fixture()
      {:ok, _} = Firefly.Groups.create_group(%{name: "beta"}, admin)
      {:ok, _} = Firefly.Groups.create_group(%{name: "alpha"}, admin)
      user = logged_in_user(dc_login(conn, Map.put(@fields, "groups", "beta")))
      refute Enum.any?(role_names(user))

      {:ok, _} =
        SiteSettings.update(
          %{
            "discourse_connect_overrides_email" => "true",
            "discourse_connect_overrides_username" => "true",
            "discourse_connect_overrides_name" => "true",
            "discourse_connect_sync_staff" => "true",
            "discourse_connect_overrides_groups" => "true"
          },
          admin
        )

      conn =
        dc_login(
          build_conn(),
          %{
            @fields
            | "email" => "new@example.com",
              "username" => "rear-admiral",
              "name" => "Rear Admiral Hopper"
          }
          |> Map.merge(%{"admin" => "true", "moderator" => "true", "groups" => "beta,missing"})
        )

      user = logged_in_user(conn)

      assert %{email: "new@example.com", username: "rear-admiral", name: "Rear Admiral Hopper"} =
               user

      assert User.confirmed?(user)
      assert Firefly.Forums.admin?(user)
      assert Enum.sort(role_names(user)) == ~w(admin beta moderator)
      refute Repo.get_by(Role, name: "missing")

      conn =
        dc_login(
          build_conn(),
          Map.merge(@fields, %{"admin" => "false", "groups" => "", "add_groups" => "alpha"})
        )

      user = logged_in_user(conn)
      refute Firefly.Forums.admin?(user)
      assert Enum.sort(role_names(user)) == ~w(alpha moderator)

      # A username taken here keeps the old one.
      user_fixture(%{username: "taken"})
      conn = dc_login(build_conn(), %{@fields | "username" => "taken"})
      assert logged_in_user(conn).username == "grace"

      actions =
        Repo.all(from(a in Firefly.Forums.StaffAction, select: {a.action, a.actor_id}))

      assert {"role.grant", nil} in actions
      assert {"role.revoke", nil} in actions
    end

    test "an avatar it can't fetch leaves the avatar alone", %{conn: conn} do
      {:ok, _} =
        SiteSettings.update(%{"discourse_connect_overrides_avatar" => "true"}, admin_fixture())

      conn = dc_login(conn, Map.put(@fields, "avatar_url", "http://127.0.0.1/avatar.png"))
      user = logged_in_user(conn)
      assert user.avatar_upload_id == nil

      assert %{"discourse_connect" => %{info: %{"avatar_url" => "http://127.0.0.1/avatar.png"}}} =
               Auth.identities(user)
    end

    test "a logged-in member connects their account", %{conn: conn} do
      user = user_fixture()
      {conn, request} = dc_start(log_in_as(conn, user))
      answer = dc_answer(Map.put(@fields, "nonce", request["nonce"]))
      conn = get(recycle(conn), "/auth/discourse_connect/callback", answer)
      assert redirected_to(conn) == ~p"/settings/logins"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Example ID account connected."
      assert %{"discourse_connect" => %{uid: "42"}} = Auth.identities(user)
    end

    test "is refused while not configured", %{conn: conn} do
      put_config(Firefly.Auth.DiscourseConnect, [])
      conn = get(conn, "/auth/discourse_connect")
      assert redirected_to(conn) == ~p"/login"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "DiscourseConnect login isn't enabled."
    end
  end

  describe "the staff settings" do
    test "list which login methods are on", %{conn: conn} do
      conn
      |> log_in_as(admin_fixture())
      |> visit(~p"/staff/settings")
      |> assert_has("#login-methods li", text: "GitHub: on")
      |> assert_has("#login-methods li", text: "DiscourseConnect: off")
      |> assert_has("#settings-logins label", text: "Sync groups from DiscourseConnect")
    end
  end

  defp role_names(user) do
    user
    |> Repo.preload(:roles, force: true)
    |> Map.fetch!(:roles)
    |> Enum.map(& &1.name)
    |> Enum.reject(&Firefly.TrustLevels.group?/1)
  end

  defp merge_kid(jwk) do
    {_, map} = JOSE.JWK.to_map(jwk)
    JOSE.JWK.from_map(Map.put(map, "kid", "key-1"))
  end
end
