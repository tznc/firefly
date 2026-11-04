defmodule Firefly.TelemetryTest do
  # Not async: telemetry handlers see every process's events.
  use Firefly.DataCase, async: false

  import Firefly.Fixtures

  alias Firefly.{Notifications, Webhooks}

  defp listen(events) do
    ref = :telemetry_test.attach_event_handlers(self(), events)
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  test "notifications count as they're created, by kind" do
    ref = listen([[:firefly, :notifications, :created]])
    user = user_fixture()

    {:ok, _} =
      Notifications.notify(user, %{kind: "staff", subject: "Hello", body: "Hi", url: "/"})

    assert_received {[:firefly, :notifications, :created], ^ref, %{count: 1}, %{kind: "staff"}}
  end

  test "the notification fan-out is a span named by its event" do
    ref = listen([[:firefly, :notifications, :dispatch, :stop]])
    author = user_fixture()
    thread = thread_fixture(category_fixture(), author)
    {:ok, post} = Firefly.Discussion.create_post(thread, author, %{body: "A reply"})

    {:noreply, _} =
      Firefly.Notifications.Dispatcher.handle_cast(
        {{:post_edited, post}, Firefly.Telemetry.current_context()},
        :nostate
      )

    assert_received {[:firefly, :notifications, :dispatch, :stop], ^ref, %{duration: _},
                     %{event: :post_edited}}
  end

  test "webhook deliveries are spans with their outcome; queues report their depth" do
    ref =
      listen([[:firefly, :webhooks, :delivery, :stop], [:firefly, :queue, :depth]])

    {:ok, webhook} =
      Webhooks.create(
        %{"payload_url" => "http://127.0.0.1:9/hook", "wildcard" => "true"},
        admin_fixture()
      )

    :ok = Webhooks.ping(webhook)
    Firefly.Telemetry.measure_queues()

    assert_received {[:firefly, :queue, :depth], ^ref, %{depth: 1}, %{queue: "webhooks"}}
    assert_received {[:firefly, :queue, :depth], ^ref, %{depth: 0}, %{queue: "plugin_events"}}

    assert Webhooks.deliver_due() == 0

    assert_received {[:firefly, :webhooks, :delivery, :stop], ^ref, %{duration: _},
                     %{type: "ping", result: "failure"}}
  end

  test "plugin hook calls report the plugin, hook and outcome" do
    ref = listen([[:firefly, :plugins, :hook]])

    Firefly.Plugins.Health.record(%{id: "demo"}, "on_post_created", {:ok, nil}, 1_500)

    assert_received {[:firefly, :plugins, :hook], ^ref, %{count: 1, duration: duration},
                     %{plugin: "demo", hook: "on_post_created", result: "ok"}}

    assert System.convert_time_unit(duration, :native, :microsecond) == 1_500
  end
end
