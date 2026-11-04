defmodule Firefly.WebhooksTest do
  use Firefly.DataCase

  alias Firefly.{Discussion, Groups, Notifications, Webhooks}
  alias Firefly.Moderation.StaffAction
  alias Firefly.Webhooks.{Delivery, DeliveryWorker, Webhook}

  import Firefly.Fixtures
  import ExUnit.CaptureLog

  setup do
    %{admin: admin_fixture(), author: user_fixture(), category: category_fixture()}
  end

  defp hook(admin, attrs) do
    {:ok, webhook} =
      Webhooks.create(Map.merge(%{"payload_url" => "http://127.0.0.1:9/hook"}, attrs), admin)

    webhook
  end

  defp deliveries(webhook), do: Repo.all(where(Delivery, webhook_id: ^webhook.id))

  test "events are queued for the webhooks whose types want them", ctx do
    posts = hook(ctx.admin, %{"event_types" => ["post"]})
    topics = hook(ctx.admin, %{"event_types" => ["topic"]})
    everything = hook(ctx.admin, %{"wildcard" => "true"})

    thread = thread_fixture(category_fixture("Fresh"), ctx.author)
    {:ok, _} = Discussion.create_post(thread, ctx.author, %{body: "A reply"})

    assert [%{event: "post_created", payload: %{"post" => %{"body" => "A reply"}}}] =
             deliveries(posts)

    assert [%{event: "thread_created"}] = deliveries(topics)

    assert ["category_created", "post_created", "thread_created"] =
             everything |> deliveries() |> Enum.map(& &1.event) |> Enum.sort()

    assert Repo.aggregate(where(StaffAction, action: "webhook.create"), :count) == 3
  end

  test "category, tag and group filters narrow the events", ctx do
    other = category_fixture("Other")
    {:ok, group} = Groups.create_role("vip")
    vip = user_fixture()
    {:ok, _} = Groups.add_role(vip, group)

    in_category =
      hook(ctx.admin, %{"event_types" => ["topic"], "category_ids" => [to_string(other.id)]})

    tagged = hook(ctx.admin, %{"event_types" => ["topic"], "tag_names" => "otp, beam"})

    by_group =
      hook(ctx.admin, %{"event_types" => ["topic"], "group_ids" => [to_string(group.id)]})

    thread_fixture(ctx.category, ctx.author, %{title: "Plain"})
    thread_fixture(other, ctx.author, %{title: "Elsewhere"})
    thread_fixture(ctx.category, ctx.author, %{title: "Tagged", tags: "otp"})
    thread_fixture(ctx.category, vip, %{title: "VIP"})

    titles = fn webhook ->
      webhook |> deliveries() |> Enum.map(& &1.payload["thread"]["title"])
    end

    assert titles.(in_category) == ["Elsewhere"]
    assert titles.(tagged) == ["Tagged"]
    assert titles.(by_group) == ["VIP"]
    assert in_category.tag_names == [] and tagged.tag_names == ["otp", "beam"]
  end

  test "failed deliveries are retried with backoff, then the webhook is turned off", ctx do
    webhook = hook(ctx.admin, %{"wildcard" => "true", "secret" => "a secret of some length"})
    :ok = Webhooks.ping(webhook)
    [%{id: id}] = deliveries(webhook)
    assert_enqueued(worker: DeliveryWorker, args: %{delivery_id: id}, queue: :webhooks)
    now = DateTime.utc_now()

    assert {:error, error} = perform_job(DeliveryWorker, %{delivery_id: id})
    assert error =~ "private address"
    [delivery] = deliveries(webhook)
    assert delivery.status == "pending"
    assert delivery.attempts == 1
    assert delivery.error =~ "private address"
    assert DateTime.diff(delivery.run_at, now) == 30

    assert %{"X-Firefly-Event" => "ping", "X-Firefly-Event-Signature" => "sha256=" <> _} =
             delivery.request_headers

    # Each attempt counts; the tenth in a row turns it off.
    Repo.update_all(where(Webhook, id: ^webhook.id), set: [failure_count: 9])
    capture_log(fn -> assert {:error, _} = Webhooks.deliver(id, DateTime.add(now, 31)) end)

    webhook = Repo.reload!(webhook)
    refute webhook.active
    assert %{actor_id: nil} = Repo.get_by(StaffAction, action: "webhook.auto_disable")
    assert [%{kind: "webhook_disabled"}] = Notifications.notifications_for(ctx.admin)

    # Deliveries for a webhook that's off are skipped.
    :ok = Webhooks.ping(webhook)
    skipped = webhook |> deliveries() |> Enum.map(& &1.id) |> Enum.max()
    assert :ok = perform_job(DeliveryWorker, %{delivery_id: skipped})
    assert Repo.get!(Delivery, skipped).status == "skipped"

    {:ok, webhook} = Webhooks.update(webhook, %{"active" => "true"}, ctx.admin)
    assert webhook.failure_count == 0
  end

  test "gives up after five attempts", ctx do
    webhook = hook(ctx.admin, %{"wildcard" => "true"})
    :ok = Webhooks.ping(webhook)
    [delivery] = deliveries(webhook)
    Repo.update!(change(delivery, attempts: 4))

    # The job's fifth attempt, its last: Oban discards it.
    assert Enum.map(1..4, &DeliveryWorker.backoff(%Oban.Job{attempt: &1})) == [30, 120, 480, 1920]
    assert {:error, _} = perform_job(DeliveryWorker, %{delivery_id: delivery.id}, attempt: 5)
    assert [%{status: "failed", attempts: 5}] = deliveries(webhook)
  end

  test "signatures are HMAC-SHA256 of the body" do
    assert Webhooks.signature("secret", "body") ==
             "sha256=" <>
               Base.encode16(:crypto.mac(:hmac, :sha256, "secret", "body"), case: :lower)
  end

  test "event types: known ones, and the first word of new ones" do
    assert Webhooks.event_type("thread_created") == "topic"
    assert Webhooks.event_type("category_deleted") == "category"
    assert Webhooks.event_type("post_approved") == "review"
    assert Webhooks.event_type("chat_message_created") == "chat"
  end

  test "webhooks are validated", ctx do
    assert {:error, changeset} = Webhooks.create(%{"payload_url" => "ftp://x"}, ctx.admin)

    assert %{payload_url: ["must be an http or https URL"], event_types: [_]} =
             errors_on(changeset)
  end
end
