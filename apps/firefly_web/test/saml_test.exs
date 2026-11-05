defmodule FireflyWeb.SAMLTest do
  use FireflyWeb.ConnCase

  alias Firefly.{Repo, SAMLTestIdP, SiteSettings}
  alias Firefly.Accounts.{Auth, TwoFactor, User, UserIdentity}

  setup do
    SAMLTestIdP.setup()
  end

  defp logged_in_user(conn) do
    case session_user_id(conn) do
      nil -> nil
      id -> Repo.get(User, id)
    end
  end

  # Our redirect to the identity provider, and the request id in it.
  defp start(conn, path \\ "/auth/saml") do
    conn = get(conn, path)
    query = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    xml = query["SAMLRequest"] |> Base.decode64!() |> :zlib.unzip()
    [_, id] = Regex.run(~r/ ID="([^"]+)"/, xml)
    {conn, id, query}
  end

  # The identity provider's page posts the response: no cookies come along.
  defp post_response(response, relay_state \\ nil) do
    post(build_conn(), "/auth/saml/acs", %{
      "SAMLResponse" => response,
      "RelayState" => relay_state
    })
  end

  defp login(conn, opts) do
    {conn, id, _query} = start(conn)
    acs = post_response(SAMLTestIdP.response(id, opts))
    assert redirected_to(acs) == ~p"/auth/saml/finish"
    get(recycle(conn), ~p"/auth/saml/finish")
  end

  test "the login page offers it by its name", %{conn: conn} do
    conn |> visit(~p"/login") |> assert_has("#login-saml", text: "Log in with Corp SAML")

    SAMLTestIdP.setup(%{"saml_enabled" => "false"})
    conn |> visit(~p"/login") |> refute_has("#login-saml")
    assert redirected_to(get(build_conn(), "/auth/saml")) == ~p"/login"
  end

  test "logs in, creating a user linked by the account id", %{conn: conn} do
    conn =
      login(conn,
        name_id: "emp-1",
        attributes: %{"email" => ["ada@corp.example"], "username" => ["ada"], "name" => ["Ada L"]}
      )

    assert redirected_to(conn) == ~p"/"
    user = logged_in_user(conn)
    assert {user.username, user.email, user.name} == {"ada", "ada@corp.example", "Ada L"}
    assert Repo.get_by(UserIdentity, provider: "saml", uid: "emp-1").user_id == user.id

    # The next login is the same account.
    again = login(build_conn(), name_id: "emp-1")
    assert logged_in_user(again).id == user.id
  end

  test "goes back to the page the login started from", %{conn: conn} do
    {conn, id, query} = start(conn, "/auth/saml?return_to=/latest")
    assert query["RelayState"] == "/latest"
    post_response(SAMLTestIdP.response(id), "https://evil.example/")
    assert redirected_to(get(recycle(conn), ~p"/auth/saml/finish")) == "/latest"
  end

  test "an answer only logs in the browser that asked (no login CSRF)", %{conn: conn} do
    {_attacker, id, _query} = start(conn)
    post_response(SAMLTestIdP.response(id, name_id: "attacker"))

    victim = get(build_conn(), ~p"/auth/saml/finish")
    assert redirected_to(victim) == ~p"/login"
    refute logged_in_user(victim)
  end

  test "refused responses send the browser back with why", %{conn: conn} do
    {conn, id, _query} = start(conn)
    forged = SAMLTestIdP.response(id, key: SAMLTestIdP.key("other"))
    acs = post_response(forged)
    assert redirected_to(acs) == ~p"/auth/saml/finish?error=failed"
    # The response's page didn't touch the session it didn't get.
    refute get_resp_header(acs, "set-cookie") |> Enum.any?(&String.starts_with?(&1, "_firestorm"))

    conn = get(recycle(conn), redirected_to(acs))
    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Corp SAML login failed. Try again."
    refute logged_in_user(conn)

    assert redirected_to(post_response("garbage")) == ~p"/auth/saml/finish?error=failed"

    assert redirected_to(post_response(SAMLTestIdP.response(nil))) ==
             ~p"/auth/saml/finish?error=unsolicited"
  end

  test "logins started at the identity provider, when allowed" do
    SAMLTestIdP.setup(%{"saml_idp_initiated" => "true"})
    acs = post_response(SAMLTestIdP.response(nil, name_id: "emp-7"), "/latest")
    "/auth/saml/finish?ticket=" <> _ = path = redirected_to(acs)

    conn = get(build_conn(), path)
    assert redirected_to(conn) == "/latest"
    assert logged_in_user(conn)
    # A ticket works once.
    refute logged_in_user(get(build_conn(), path))
  end

  test "asks members with two-factor for their second factor", %{conn: conn} do
    user = user_fixture()
    {:ok, _} = Auth.connect(user, %{provider: :saml, uid: "emp-2"})
    secret = TwoFactor.new_secret()
    code = NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30)
    {:ok, _codes} = TwoFactor.enable_totp(user, secret, code)

    conn = login(conn, name_id: "emp-2")
    assert redirected_to(conn) == ~p"/login/two-factor"
    refute logged_in_user(conn)
  end

  test "respects closed registrations", %{conn: conn} do
    {:ok, _} = SiteSettings.update(%{"invite_only" => "true"}, admin_fixture())
    conn = login(conn, name_id: "emp-3")
    assert redirected_to(conn) == ~p"/login"
    refute logged_in_user(conn)
  end

  test "is a single sign-on provider: SSO only hides passwords", %{conn: conn} do
    original = Application.get_env(:firefly, Auth)
    Application.put_env(:firefly, Auth, sso_only: true)
    on_exit(fn -> Application.put_env(:firefly, Auth, original || []) end)

    assert Auth.sso_only?()
    assert Auth.enabled_providers() == [:saml]
    conn |> visit(~p"/auth/identity") |> assert_path(~p"/login")
  end

  test "connects the account from the settings", %{conn: conn} do
    user = user_fixture()
    conn = log_in_as(conn, user)

    conn |> visit(~p"/settings/logins") |> assert_has("#login-saml", text: "Corp SAML")

    conn = login(conn, name_id: "emp-4")
    assert redirected_to(conn) == ~p"/settings/logins"
    assert Repo.get_by(UserIdentity, provider: "saml", uid: "emp-4").user_id == user.id
  end

  test "serves our metadata, even before logins are on" do
    SAMLTestIdP.setup(%{"saml_enabled" => "false"})
    conn = get(build_conn(), "/saml/metadata")
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "application/samlmetadata+xml"
    assert response(conn, 200) =~ ~s{Location="#{url(~p"/auth/saml/acs")}"}
  end
end
