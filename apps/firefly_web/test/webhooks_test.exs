defmodule FireflyWeb.WebhooksTest do
  # Changes global config (which local addresses may be reached).
  use FireflyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest, only: [element: 2, render_click: 1]

  alias Firefly.{Repo, Webhooks}
  alias Firefly.Plugins.HTTP
  alias Firefly.Webhooks.{Delivery, Webhook}

  # Receives deliveries and tells the test.
  defmodule Receiver do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, test) do
      {:ok, body, conn} = read_body(conn)
      send(test, {:delivery, conn.request_path, conn.req_headers, body})

      case conn.request_path do
        "/fail" -> send_resp(conn, 500, "nope")
        _ -> send_resp(conn, 200, "thanks")
      end
    end
  end

  setup do
    {:ok, server} =
      start_supervised({Bandit, plug: {Receiver, self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    http = Application.get_env(:firefly, HTTP, [])
    Application.put_env(:firefly, HTTP, allow_private: [{127, 0, 0, 1}])
    on_exit(fn -> Application.put_env(:firefly, HTTP, http) end)

    {:ok, admin: admin_fixture(), base: "http://127.0.0.1:#{port}"}
  end

  test "events are POSTed, signed, and logged", %{admin: admin, base: base} do
    {:ok, webhook} =
      Webhooks.create(
        %{
          "payload_url" => base <> "/ok",
          "event_types" => ["topic"],
          "secret" => "shh, it's a secret"
        },
        admin
      )

    thread = thread_fixture(category_fixture(), user_fixture(), %{title: "Hooked"})
    assert Webhooks.deliver_due() == 1

    assert_received {:delivery, "/ok", headers, body}
    headers = Map.new(headers)
    assert headers["x-firefly-event"] == "thread_created"
    assert headers["x-firefly-event-type"] == "topic"
    assert headers["content-type"] == "application/json"
    assert headers["x-firefly-event-signature"] == Webhooks.signature("shh, it's a secret", body)

    assert %{"event" => "thread_created", "data" => %{"thread" => %{"id" => id}}} =
             Jason.decode!(body)

    assert id == thread.id

    assert [%Delivery{status: "delivered", response_status: 200, response_body: "thanks"}] =
             Webhooks.deliveries(webhook)

    assert %Webhook{last_status: "delivered", failure_count: 0} = Repo.reload!(webhook)
  end

  test "admins add a webhook, ping it and redeliver from the log", %{
    conn: conn,
    admin: admin,
    base: base
  } do
    session =
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/webhooks")
      |> assert_has("#webhooks-empty")
      |> fill_in("Payload URL", with: base <> "/fail")
      |> check("Send every event")
      |> click_button("Add webhook")
      |> assert_has("#flash-info", text: "Webhook added.")
      |> click_button("Ping")
      |> assert_has("#flash-info", text: "Ping queued.")

    Webhooks.deliver_due()
    assert_received {:delivery, "/fail", _headers, _body}

    [delivery] = Webhooks.list() |> hd() |> Webhooks.deliveries()

    session
    |> click_button("Refresh")
    |> assert_has("#delivery-#{delivery.id}", text: "HTTP 500")
    |> unwrap(&render_click(element(&1, "#delivery-#{delivery.id} button[phx-click=toggle]")))
    |> assert_has("#delivery-#{delivery.id} pre", text: "nope")
    |> click_button("#delivery-#{delivery.id} button", "Redeliver")
    |> assert_has("#flash-info", text: "Delivery queued again.")

    assert Repo.aggregate(Delivery, :count) == 2
  end

  test "members can't see webhooks", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/webhooks")
    |> assert_path(~p"/")
  end
end
