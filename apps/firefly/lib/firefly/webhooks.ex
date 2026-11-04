defmodule Firefly.Webhooks do
  @moduledoc """
  The Webhooks context: outbound webhooks admins set up at `/staff/webhooks`
  (`Firefly.Webhooks.Webhook`), as in Discourse.

  Events are the ones plugins get (see `Firefly.Plugins.Events`):
  `Firefly.Plugins.Events.emit/3` also queues them here, so every event
  point serves both. Each event has a type, the group webhooks subscribe
  to: `topic` (`thread_created`, `solved`), `post` (`post_created`,
  `post_edited`, `post_deleted`, `poll_closed`), `user`
  (`user_registered`), `category` (`category_created`, `_updated`,
  `_deleted`), `flag` (`flag_raised`), `review` (`post_approved`,
  `post_rejected`) and `like` (`post_liked`). Any other event's type is the
  first word of its name (`chat_message_created` is `chat`), so new kinds
  of events need no change here. A webhook gets the types it picked, or
  everything (`wildcard`); category, tag and group filters narrow that to
  events in those categories, on threads with those tags or by members of
  those groups (an event without a category, tags or actor isn't filtered
  by it). Unlike plugins' events, webhooks also get events in restricted
  categories: admins chose where they go. `ping` (`ping/1`) tests one.

  Each event becomes a `Firefly.Webhooks.Delivery` per webhook, POSTed
  (JSON `{"event", "type", "event_id", "data"}`) by a background job
  (`Firefly.Webhooks.DeliveryWorker`, the `webhooks` queue) with the headers `X-Firefly-Event`,
  `X-Firefly-Event-Type`, `X-Firefly-Event-Id`, `X-Firefly-Delivery` and,
  with a secret, `X-Firefly-Event-Signature: sha256=<HMAC-SHA256 of the
  body>`. Requests go through the same server-side request forgery guard
  as plugins' and link previews' (`Firefly.Plugins.HTTP`): public addresses
  only, no redirects, 5 seconds. A 2xx answer is a delivery; anything else
  is retried after 30 seconds, 2, 8 and 32 minutes, then given up. After
  10 failed attempts in a row a webhook is turned off, with a staff log
  entry and a notification to admins. The log keeps the last attempt's
  request and response (bodies truncated); a delivery can be sent again.
  Creating, changing and deleting webhooks goes to the staff log.
  """

  use Boundary, top_level?: true, check: [out: false], exports: [Webhook, Delivery]

  import Ecto.Query

  require Logger

  alias Firefly.{Notifications, Repo}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Category, Thread}
  alias Firefly.Groups.RoleMembership
  alias Firefly.Moderation.StaffLog
  alias Firefly.Plugins.HTTP
  alias Firefly.Webhooks.{Delivery, DeliveryWorker, Webhook}

  @types %{
    "thread_created" => "topic",
    "solved" => "topic",
    "post_created" => "post",
    "post_edited" => "post",
    "post_deleted" => "post",
    "poll_closed" => "post",
    "user_registered" => "user",
    "flag_raised" => "flag",
    "post_liked" => "like",
    "post_approved" => "review",
    "post_rejected" => "review"
  }
  @max_attempts 5
  @disable_after 10
  @truncate 10_000

  ## Managing webhooks

  @doc "Every webhook, oldest first."
  def list, do: Repo.all(from(w in Webhook, order_by: w.id))

  def get(id), do: Repo.get(Webhook, id)

  @doc "A changeset for the webhook form."
  def change(webhook \\ %Webhook{}, attrs \\ %{}), do: Webhook.changeset(webhook, attrs)

  @doc "Creates a webhook as `admin`."
  def create(attrs, %User{} = admin), do: save(%Webhook{}, attrs, admin, "webhook.create")

  @doc "Updates `webhook` as `admin`."
  def update(%Webhook{} = webhook, attrs, %User{} = admin),
    do: save(webhook, attrs, admin, "webhook.update")

  defp save(webhook, attrs, admin, action) do
    changeset = Webhook.changeset(webhook, attrs)

    Repo.transact(fn ->
      with {:ok, saved} <- Repo.insert_or_update(changeset) do
        details =
          changeset
          |> StaffLog.changes()
          |> Map.delete(:secret)
          |> Map.put(:url, saved.payload_url)

        StaffLog.record(admin, action, {"webhook", saved.id}, details)
        {:ok, saved}
      end
    end)
  end

  @doc "Deletes `webhook` (and its delivery log) as `admin`."
  def delete(%Webhook{} = webhook, %User{} = admin) do
    {:ok, _} =
      Repo.transact(fn ->
        Repo.delete!(webhook)

        StaffLog.record(admin, "webhook.delete", {"webhook", webhook.id}, %{
          url: webhook.payload_url
        })

        {:ok, webhook}
      end)

    :ok
  end

  @doc "`webhook`'s latest deliveries, newest first."
  def deliveries(%Webhook{id: id}, limit \\ 50) do
    Delivery
    |> where([d], d.webhook_id == ^id)
    |> order_by(desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Queues a `ping` event for `webhook`, to test it."
  def ping(%Webhook{} = webhook) do
    queue([webhook], "ping", %{ping: "OK"})
    :ok
  end

  @doc "Sends `delivery`'s event again, as a new delivery with the same event id."
  def redeliver(%Delivery{} = delivery) do
    %{id: id} =
      Repo.insert!(%Delivery{
        webhook_id: delivery.webhook_id,
        event_id: delivery.event_id,
        event: delivery.event,
        payload: delivery.payload,
        run_at: DateTime.utc_now()
      })

    send_later([id])
  end

  # A job per delivery (see Firefly.Webhooks.DeliveryWorker), in the
  # caller's transaction.
  defp send_later(ids) do
    for id <- ids, do: {:ok, _job} = Firefly.Jobs.insert(DeliveryWorker.new(%{delivery_id: id}))
    :ok
  end

  ## Events

  @doc "An event's type (see the moduledoc)."
  def event_type("category_" <> _), do: "category"
  def event_type(event), do: Map.get_lazy(@types, event, fn -> hd(String.split(event, "_")) end)

  @doc """
  Queues `event` for the active webhooks that want it. `data` is the
  payload or a function building it (only called if one does). Options as
  `Firefly.Plugins.Events.emit/3`: `:thread` (or a function loading it),
  `:actor`, and `:category` for category events.
  """
  def enqueue(event, data, opts \\ []) do
    type = event_type(event)

    hooks =
      Repo.all(from(w in Webhook, where: w.active and (w.wildcard or ^type in w.event_types)))

    hooks = if Enum.any?(hooks, &filtered?/1), do: filter(hooks, context(opts)), else: hooks
    if hooks != [], do: queue(hooks, event, if(is_function(data, 0), do: data.(), else: data))
    :ok
  end

  defp filtered?(hook),
    do: hook.category_ids != [] or hook.tag_names != [] or hook.group_ids != []

  defp context(opts) do
    thread = if is_function(opts[:thread], 0), do: opts[:thread].(), else: opts[:thread]

    %{
      category_id:
        case {thread, opts[:category]} do
          {%Thread{category_id: id}, _} -> id
          {_, %Category{id: id}} -> id
          _ -> nil
        end,
      tags: if(thread, do: Enum.map(Repo.preload(thread, :tags).tags, & &1.name)),
      groups: group_ids(opts[:actor])
    }
  end

  defp group_ids(%User{id: id}),
    do: Repo.all(from(m in RoleMembership, where: m.user_id == ^id, select: m.role_id))

  defp group_ids(_actor), do: nil

  defp filter(hooks, context) do
    Enum.filter(hooks, fn hook ->
      allows?(hook.category_ids, context.category_id && [context.category_id]) and
        allows?(hook.tag_names, context.tags) and allows?(hook.group_ids, context.groups)
    end)
  end

  defp allows?([], _values), do: true
  defp allows?(_wanted, nil), do: true
  defp allows?(wanted, values), do: Enum.any?(values, &(&1 in wanted))

  defp queue(hooks, event, payload) do
    event_id = Ecto.UUID.generate()
    now = NaiveDateTime.utc_now()

    rows =
      for hook <- hooks do
        %{
          webhook_id: hook.id,
          event_id: event_id,
          event: event,
          payload: payload,
          status: "pending",
          attempts: 0,
          run_at: DateTime.utc_now(),
          inserted_at: now,
          updated_at: now
        }
      end

    {_count, inserted} = Repo.insert_all(Delivery, rows, returning: [:id])
    send_later(Enum.map(inserted, & &1.id))
  end

  ## Delivering

  @doc "How many deliveries are waiting to be sent (or retried)."
  @spec pending_count() :: non_neg_integer
  def pending_count, do: Repo.aggregate(where(Delivery, status: "pending"), :count)

  @doc """
  Attempts the delivery `id` now (its job's work, see
  `Firefly.Webhooks.DeliveryWorker`): `:ok` when it's done (delivered,
  skipped, or no longer pending), `{:error, reason}` when it failed (retried
  until it has had #{@max_attempts} attempts).
  """
  @spec deliver(pos_integer, DateTime.t()) :: :ok | {:error, String.t()}
  def deliver(id, now \\ DateTime.utc_now()) do
    with %Delivery{status: "pending"} = row <- Repo.get(Delivery, id),
         0 <- attempt_delivery(row, now),
         %Delivery{status: status, error: error} when status in ~w(pending failed) <-
           Repo.get(Delivery, id) do
      {:error, error}
    else
      _done -> :ok
    end
  end

  defp attempt_delivery(row, now) do
    case Repo.get(Webhook, row.webhook_id) do
      %Webhook{active: true} = hook ->
        Firefly.Telemetry.span(
          [:firefly, :webhooks, :delivery],
          %{type: event_type(row.event)},
          fn ->
            delivered = attempt(hook, row, now)
            {delivered, %{result: if(delivered == 1, do: "success", else: "failure")}}
          end
        )

      _off ->
        Repo.update!(Ecto.Changeset.change(row, status: "skipped", error: "The webhook is off."))
        0
    end
  end

  defp attempt(hook, row, now) do
    body =
      Jason.encode!(%{
        event: row.event,
        type: event_type(row.event),
        event_id: row.event_id,
        data: row.payload
      })

    headers = headers(hook, row, body)
    started = System.monotonic_time(:millisecond)

    result =
      HTTP.fetch([String.downcase(URI.parse(hook.payload_url).host || "")], %{
        "url" => hook.payload_url,
        "method" => "POST",
        "headers" => headers,
        "body" => body
      })

    log = %{
      attempts: row.attempts + 1,
      request_headers: headers,
      request_body: truncate(body),
      duration_ms: System.monotonic_time(:millisecond) - started
    }

    case result do
      {:ok, %{status: status} = response} when status in 200..299 ->
        succeeded(hook, row, Map.merge(log, response_log(response)), now)

      {:ok, %{status: status} = response} ->
        failed(hook, row, Map.merge(log, response_log(response)), "HTTP #{status}", now)

      {:error, _kind, message} ->
        failed(
          hook,
          row,
          Map.merge(log, %{response_status: nil, response_body: nil}),
          message,
          now
        )
    end
  end

  @doc "The signature header's value for `body` signed with `secret`."
  def signature(secret, body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  defp headers(hook, row, body) do
    base = %{
      "Content-Type" => hook.content_type,
      "User-Agent" => "Firefly-Webhooks",
      "X-Firefly-Event" => row.event,
      "X-Firefly-Event-Type" => event_type(row.event),
      "X-Firefly-Event-Id" => row.event_id,
      "X-Firefly-Delivery" => to_string(row.id)
    }

    if hook.secret in [nil, ""],
      do: base,
      else: Map.put(base, "X-Firefly-Event-Signature", signature(hook.secret, body))
  end

  defp response_log(response) do
    body = if response[:base64], do: "(binary response)", else: response.body

    %{
      response_status: response.status,
      response_headers: Map.new(response.headers, fn {k, v} -> {to_string(k), to_string(v)} end),
      response_body: truncate(body)
    }
  end

  defp truncate(text) when byte_size(text) > @truncate,
    do: String.slice(text, 0, @truncate) <> "…"

  defp truncate(text), do: text

  defp succeeded(hook, row, log, now) do
    Repo.update!(
      Ecto.Changeset.change(
        row,
        Map.merge(log, %{
          status: "delivered",
          error: nil,
          delivered_at: DateTime.truncate(now, :second)
        })
      )
    )

    Repo.update!(
      Ecto.Changeset.change(hook,
        failure_count: 0,
        last_status: "delivered",
        last_delivery_at: DateTime.truncate(now, :second)
      )
    )

    1
  end

  defp failed(hook, row, log, error, now) do
    attempts = log.attempts

    retry =
      if attempts >= @max_attempts,
        do: %{status: "failed"},
        else: %{run_at: DateTime.add(now, 30 * 4 ** (attempts - 1))}

    Repo.update!(Ecto.Changeset.change(row, Map.merge(log, Map.put(retry, :error, error))))

    {1, [failures]} =
      Webhook
      |> where([w], w.id == ^hook.id)
      |> select([w], w.failure_count)
      |> Repo.update_all(
        inc: [failure_count: 1],
        set: [last_status: "failed", last_delivery_at: DateTime.truncate(now, :second)]
      )

    if failures >= @disable_after, do: disable(hook, error)
    0
  end

  # Only the attempt that turns it off logs and notifies.
  defp disable(hook, error) do
    {count, _} =
      Webhook
      |> where([w], w.id == ^hook.id and w.active)
      |> Repo.update_all(set: [active: false])

    if count == 1 do
      StaffLog.record_system("webhook.auto_disable", {"webhook", hook.id}, %{
        url: hook.payload_url,
        error: error
      })

      Logger.warning("Webhook #{hook.id} turned off after #{@disable_after} failures: #{error}")

      for admin <- admins() do
        Notifications.notify(admin, %{
          kind: "webhook_disabled",
          subject: "A webhook was turned off after failing repeatedly",
          body: "#{hook.payload_url}: #{error}",
          url: Firefly.Endpoint.url() <> "/staff/webhooks/#{hook.id}"
        })
      end
    end
  end

  defp admins do
    User
    |> join(:inner, [u], r in assoc(u, :roles))
    |> where([u, r], r.name == "admin" and is_nil(u.deleted_at))
    |> Repo.all()
  end
end
