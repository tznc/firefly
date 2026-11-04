defmodule FireflyWeb.DiscourseConnectProviderTest do
  use FireflyWeb.ConnCase

  import Ecto.Query

  alias Firefly.{Groups, Repo, SiteSettings}
  alias Firefly.Accounts.Auth.DiscourseConnectProvider, as: Provider
  alias Firefly.Accounts.TwoFactor
  alias Firefly.Moderation.StaffAction

  @secret "a-long-client-secret-0123456789"

  setup do
    admin = admin_fixture()
    {:ok, _} = SiteSettings.update(%{"discourse_connect_provider_enabled" => "true"}, admin)

    {:ok, client} =
      Provider.create_client(
        %{
          "name" => "Docs wiki",
          "secret" => @secret,
          "hosts" => "docs.example.com\nwiki.example.com"
        },
        admin
      )

    %{admin: admin, client: client}
  end

  defp sign(payload, secret \\ @secret),
    do: :hmac |> :crypto.mac(:sha256, secret, payload) |> Base.encode16(case: :lower)

  # What a client sends: its nonce and return URL, signed.
  defp request_path(fields, secret \\ @secret) do
    payload =
      %{
        "nonce" => "n-#{System.unique_integer([:positive])}",
        "return_sso_url" => "https://docs.example.com/sso"
      }
      |> Map.merge(fields)
      |> URI.encode_query()
      |> Base.encode64()

    "/session/sso_provider?" <>
      URI.encode_query(%{"sso" => payload, "sig" => sign(payload, secret)})
  end

  # The client's view of our answer: the signature checked, the payload read.
  defp answer(conn) do
    %URI{host: "docs.example.com", path: "/sso", query: query} = URI.parse(redirected_to(conn))
    %{"sso" => sso, "sig" => sig} = URI.decode_query(query)
    assert sig == sign(sso)
    sso |> Base.decode64!() |> URI.decode_query()
  end

  test "answers a logged-in member with their details, signed", %{conn: conn} do
    user = user_fixture(%{username: "ada", name: "Ada L", email: "ada@example.com"})
    {:ok, role} = Groups.create_role("writers")
    {:ok, _} = Groups.add_role(user, role)

    path = request_path(%{"nonce" => "abc123"})
    fields = conn |> log_in_as(user) |> get(path) |> answer()

    assert fields["nonce"] == "abc123"
    assert fields["return_sso_url"] == "https://docs.example.com/sso"
    assert fields["external_id"] == to_string(user.id)

    assert {fields["username"], fields["name"], fields["email"]} ==
             {"ada", "Ada L", "ada@example.com"}

    assert fields["groups"] == "writers"

    assert {fields["admin"], fields["moderator"], fields["require_activation"]} ==
             {"false", "false", "false"}

    assert fields["avatar_url"] =~ "https://"

    # A nonce is answered once.
    conn = build_conn() |> log_in_as(user) |> get(path)
    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "used already"
  end

  test "flags admins", %{conn: conn, admin: admin} do
    assert %{"admin" => "true"} = conn |> log_in_as(admin) |> get(request_path(%{})) |> answer()
  end

  test "asks visitors to log in first, then answers", %{conn: conn} do
    path = request_path(%{})
    conn = get(conn, path)
    assert redirected_to(conn) == ~p"/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Log in to continue to Docs wiki."

    user =
      user_fixture()
      |> Ecto.Changeset.change(password_hash: Bcrypt.hash_pwd_salt("s3cret-password"))
      |> Repo.update!()

    conn =
      post(recycle(conn), "/auth/identity/callback", %{
        "user" => %{"username" => user.username, "password" => "s3cret-password"}
      })

    assert redirected_to(conn) == path

    assert %{"external_id" => id} = conn |> recycle() |> get(path) |> answer()
    assert id == to_string(user.id)
  end

  test "prompt=none answers failed instead of asking to log in", %{conn: conn} do
    assert %{"failed" => "true"} = conn |> get(request_path(%{"prompt" => "none"})) |> answer()
  end

  test "requires two-factor when the setting says so", %{conn: conn, admin: admin} do
    {:ok, _} =
      SiteSettings.update(%{"discourse_connect_provider_require_two_factor" => "true"}, admin)

    user = user_fixture()
    conn = conn |> log_in_as(user) |> get(request_path(%{}))
    assert redirected_to(conn) == ~p"/settings/security"

    secret = TwoFactor.new_secret()
    code = NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30)
    {:ok, _codes} = TwoFactor.enable_totp(user, secret, code)

    assert %{"external_id" => _} =
             build_conn() |> log_in_as(user) |> get(request_path(%{})) |> answer()
  end

  test "refuses bad signatures, other secrets and unlisted return hosts", %{conn: conn} do
    user = user_fixture()
    conn = log_in_as(conn, user)

    for path <- [
          request_path(%{}, "someone-elses-secret-0123456789"),
          request_path(%{"return_sso_url" => "https://evil.example.com/sso"}),
          request_path(%{"return_sso_url" => "https://docs.example.com.evil.example/sso"}),
          request_path(%{"return_sso_url" => "javascript:alert(1)"}),
          request_path(%{"nonce" => ""}),
          "/session/sso_provider?sso=bm9wZQ%3D%3D&sig=00",
          "/session/sso_provider"
        ] do
      conn = get(conn, path)
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end
  end

  test "does nothing while off", %{conn: conn, admin: admin} do
    {:ok, _} = SiteSettings.update(%{"discourse_connect_provider_enabled" => "false"}, admin)
    conn = conn |> log_in_as(user_fixture()) |> get(request_path(%{}))
    assert redirected_to(conn) == "/"
  end

  test "a logout request logs out here and goes back", %{conn: conn} do
    conn = conn |> log_in_as(user_fixture()) |> get(request_path(%{"logout" => "true"}))
    assert redirected_to(conn) == "https://docs.example.com/sso"
    refute get_session(conn, :current_user)
  end

  describe "the staff page" do
    test "adds, changes and removes sites, in the staff log", %{
      conn: conn,
      admin: admin,
      client: client
    } do
      session = conn |> log_in_as(admin) |> visit(~p"/staff/discourse-connect")

      session
      |> assert_has("#client-#{client.id}", text: "docs.example.com, wiki.example.com")
      |> fill_in("Name", with: "Shop")
      |> fill_in("Hosts it may return to", with: "shop.example.com")
      |> click_button("Add site")
      |> assert_has("#clients li", text: "Shop")

      shop = Enum.find(Provider.list_clients(), &(&1.name == "Shop"))
      assert byte_size(shop.secret) >= 32
      assert shop.allowed_hosts == ["shop.example.com"]

      session
      |> click_button("#client-#{shop.id} button", "Edit")
      |> fill_in("Hosts it may return to", with: "shop.example.com, store.example.com")
      |> click_button("Save")
      |> click_button("#client-#{client.id} button", "Remove")
      |> refute_has("#client-#{client.id}")

      assert Provider.get_client!(shop.id).allowed_hosts == [
               "shop.example.com",
               "store.example.com"
             ]

      actions =
        Repo.all(
          from(a in StaffAction,
            where: like(a.action, "discourse_connect_client.%"),
            select: a.action
          )
        )

      assert Enum.sort(actions) ==
               Enum.sort(~w(discourse_connect_client.create discourse_connect_client.create
                            discourse_connect_client.update discourse_connect_client.delete))
    end

    test "is for admins only", %{conn: conn} do
      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/staff/discourse-connect")
      |> assert_path(~p"/")
    end

    test "checks hosts" do
      changeset =
        Provider.change_client(%Firefly.Accounts.Auth.DiscourseConnectClient{}, %{
          "name" => "x",
          "secret" => "s",
          "hosts" => "https://x/"
        })

      refute changeset.valid?
    end
  end
end
