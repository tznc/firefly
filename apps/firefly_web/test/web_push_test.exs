defmodule FireflyWeb.WebPushTest do
  use FireflyWeb.ConnCase

  require Phoenix.LiveViewTest

  alias Firefly.{Accounts, Notifications, Repo}
  alias Firefly.Notifications.WebPush
  alias Firefly.Notifications.WebPush.{Encryption, Subscription, VAPID}

  # A push service: records each push and answers 201, or 410 for a
  # subscription the browser dropped.
  defmodule FakePushService do
    @moduledoc false
    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {:push, conn.request_path, Map.new(conn.req_headers), body})
      send_resp(conn, if(conn.request_path == "/gone", do: 410, else: 201), "")
    end
  end

  setup do
    {public, private} = VAPID.generate_keys()
    previous = Application.get_env(:firefly, WebPush)

    Application.put_env(:firefly, WebPush,
      async: false,
      public_key: public,
      private_key: private,
      subject: "mailto:admin@example.com"
    )

    on_exit(fn -> Application.put_env(:firefly, WebPush, previous) end)

    server = start_supervised!({Bandit, plug: {FakePushService, self()}, port: 0, ip: :loopback})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    user = away(user_fixture())
    %{user: user, base: "http://localhost:#{port}", public: public}
  end

  defp away(user) do
    Repo.update!(
      Ecto.Changeset.change(user,
        last_seen_at: DateTime.add(DateTime.utc_now(:second), -1, :hour)
      )
    )
  end

  # A browser's subscription, with its private key to read what it gets.
  # (Inserted directly: only https endpoints are accepted from browsers.)
  defp browser(user, endpoint) do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)

    subscription =
      Repo.insert!(%Subscription{
        user_id: user.id,
        endpoint: endpoint,
        p256dh: Base.url_encode64(public, padding: false),
        auth: Base.url_encode64(auth, padding: false)
      })

    %{subscription: subscription, public: public, private: private, auth: auth}
  end

  defp decrypt(body, %{public: ua_public, private: ua_private, auth: auth}) do
    <<salt::binary-16, _rs::32, 65, as_public::binary-65, rest::binary>> = body
    secret = :crypto.compute_key(:ecdh, as_public, ua_private, :prime256v1)
    %{key: key, nonce: nonce} = Encryption.keys(secret, auth, ua_public, as_public, salt)
    <<ciphertext::binary-size(byte_size(rest) - 16), tag::binary-16>> = rest

    plaintext =
      :crypto.crypto_one_time_aead(:aes_128_gcm, key, nonce, ciphertext, <<>>, tag, false)

    plaintext |> String.trim_trailing(<<2>>) |> Jason.decode!()
  end

  defp notify(user) do
    {:ok, notification} =
      Notifications.notify(user, %{
        kind: "promoted",
        subject: "You're now a member",
        body: "b",
        url: "http://localhost/users/1"
      })

    notification
  end

  test "a notification is pushed, encrypted and signed, to an away member's browsers", ctx do
    device = browser(ctx.user, ctx.base <> "/push/abc")
    notification = notify(ctx.user)

    assert_received {:push, "/push/abc", headers, body}
    assert headers["content-encoding"] == "aes128gcm"
    assert headers["ttl"] == "86400"
    assert "vapid t=" <> _ = headers["authorization"]
    assert headers["authorization"] =~ ", k=#{ctx.public}"

    assert decrypt(body, device) == %{
             "title" => "Firefly",
             "body" => "You're now a member",
             "url" => "/users/1",
             "tag" => "notification-#{notification.id}"
           }

    assert Repo.get!(Subscription, device.subscription.id).last_used_at
  end

  test "not while the member is on the site, unless they want pushes anyway", ctx do
    browser(ctx.user, ctx.base <> "/push/abc")
    user = Repo.update!(Ecto.Changeset.change(ctx.user, last_seen_at: DateTime.utc_now(:second)))

    notify(user)
    refute_received {:push, _, _, _}

    {:ok, user} = Accounts.update_preferences(user, %{"push_only_when_away" => "false"})
    notify(user)
    assert_received {:push, "/push/abc", _, _}
  end

  test "a dropped subscription (410) is deleted", ctx do
    device = browser(ctx.user, ctx.base <> "/gone")
    notify(ctx.user)

    assert_received {:push, "/gone", _, _}
    refute Repo.get(Subscription, device.subscription.id)
  end

  test "nothing is pushed or shown without VAPID keys", %{conn: conn} = ctx do
    browser(ctx.user, ctx.base <> "/push/abc")
    Application.put_env(:firefly, WebPush, async: false)
    refute WebPush.enabled?()

    notify(ctx.user)
    refute_received {:push, _, _, _}

    conn
    |> log_in_as(ctx.user)
    |> visit(~p"/settings/notifications")
    |> refute_has("#push-notifications")
  end

  test "browsers subscribe and unsubscribe from the settings page", %{conn: conn, user: user} do
    {:ok, view, html} =
      conn |> log_in_as(user) |> Phoenix.LiveViewTest.live(~p"/settings/notifications")

    assert html =~ "Browser push notifications"

    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    subscription = %{
      "endpoint" => "https://push.example.com/send/xyz",
      "keys" => %{
        "p256dh" => Base.url_encode64(public, padding: false),
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }
    }

    Phoenix.LiveViewTest.render_hook(view, "push_state", %{"state" => "off"})
    assert Phoenix.LiveViewTest.render(view) =~ "Off for this browser."

    html =
      Phoenix.LiveViewTest.render_hook(view, "push_subscribe", %{
        "subscription" => subscription,
        "user_agent" => "Firefox on Linux"
      })

    assert html =~ "Push notifications are on for this browser."
    assert [%Subscription{user_agent: "Firefox on Linux"}] = WebPush.subscriptions(user)

    Phoenix.LiveViewTest.render_hook(view, "push_unsubscribe", %{
      "endpoint" => subscription["endpoint"]
    })

    assert WebPush.subscriptions(user) == []
  end

  test "only https endpoints and well-formed keys are accepted", %{user: user} do
    keys = %{"p256dh" => "short", "auth" => "short"}

    assert {:error, changeset} =
             WebPush.subscribe(user, %{"endpoint" => "http://evil.example", "keys" => keys}, nil)

    assert %{endpoint: [_], p256dh: ["is invalid"], auth: ["is invalid"]} =
             Firefly.DataCase.errors_on(changeset)
  end

  test "the service worker is served from the root", %{conn: conn} do
    conn = get(conn, "/service-worker.js")
    assert response(conn, 200) =~ "showNotification"
  end

  test "mix firefly.gen.vapid_keys prints a key pair" do
    Mix.shell(Mix.Shell.Process)
    Mix.Tasks.Firefly.Gen.VapidKeys.run([])
    assert_received {:mix_shell, :info, [output]}
    assert output =~ "FIREFLY_VAPID_PUBLIC_KEY="
    assert output =~ "FIREFLY_VAPID_PRIVATE_KEY="
  after
    Mix.shell(Mix.Shell.IO)
  end
end
