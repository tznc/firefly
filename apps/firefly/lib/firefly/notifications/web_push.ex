defmodule Firefly.Notifications.WebPush do
  @moduledoc """
  Browser push notifications (Web Push), as Discourse's: members turn them
  on per browser in Settings > Notifications, and each in-app notification
  (see `Firefly.Notifications.notify/2`) is also pushed to their browsers.
  So pushes follow the same rules: nobody is notified of what someone they
  mute or ignore did, or of threads they muted or can't read.

  By default (`push_only_when_away`) a member gets pushes only while away:
  not when they were on the site in the last 10 minutes (see
  `Firefly.Accounts.Visits`), when they see the notification there anyway.

  Pushes are encrypted for the browser (RFC 8291,
  `Firefly.Notifications.WebPush.Encryption`) and signed with the site's VAPID key
  (RFC 8292, `Firefly.Notifications.WebPush.VAPID`), set by the
  `FIREFLY_VAPID_PUBLIC_KEY`, `FIREFLY_VAPID_PRIVATE_KEY` and
  `FIREFLY_VAPID_SUBJECT` environment variables (`mix
  firefly.gen.vapid_keys` makes a pair). Without them the feature is off
  and hidden. They're sent from a task, never holding up whatever created
  the notification. A push service answering 404 or 410 means the browser
  dropped the subscription: it's deleted.
  """

  import Ecto.Query
  require Logger

  alias Firefly.{Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Notifications.Notification
  alias Firefly.Notifications.WebPush.{Encryption, Subscription, VAPID}

  @away_minutes 10
  # How long the push service keeps a push for an offline browser.
  @ttl 24 * 3600
  @http_options [connect_timeout: 5_000, recv_timeout: 10_000, pool: false, with_body: true]

  defp config, do: Application.get_env(:firefly, __MODULE__, [])

  @doc "Whether push notifications are configured (VAPID keys and subject)."
  def enabled? do
    config = config()
    Enum.all?([:public_key, :private_key, :subject], &(config[&1] not in [nil, ""]))
  end

  @doc "The VAPID public key browsers subscribe with."
  def public_key, do: config()[:public_key]

  ## Subscriptions

  @doc "`user`'s subscriptions, newest first."
  def subscriptions(%User{id: user_id}) do
    Repo.all(
      from(s in Subscription, where: s.user_id == ^user_id, order_by: [desc: s.inserted_at])
    )
  end

  @doc """
  Saves a browser's subscription for `user` (`params` as the browser's
  `PushSubscription.toJSON()`: `endpoint` and `keys`), replacing any for
  the same endpoint (a browser that changed hands moves to its new user).
  """
  def subscribe(%User{} = user, params, user_agent) do
    attrs = %{
      endpoint: params["endpoint"],
      p256dh: get_in(params, ["keys", "p256dh"]),
      auth: get_in(params, ["keys", "auth"]),
      user_agent: user_agent
    }

    %Subscription{user_id: user.id}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:user_id, :p256dh, :auth, :user_agent, :updated_at]},
      conflict_target: :endpoint
    )
  end

  @doc "Removes `user`'s subscription for `endpoint`, or with id `id`."
  def unsubscribe(%User{id: user_id}, {:id, id}),
    do: Repo.delete_all(from(s in Subscription, where: s.user_id == ^user_id and s.id == ^id))

  def unsubscribe(%User{id: user_id}, endpoint) when is_binary(endpoint),
    do:
      Repo.delete_all(
        from(s in Subscription, where: s.user_id == ^user_id and s.endpoint == ^endpoint)
      )

  ## Pushing

  @doc """
  Pushes `notification` to `user`'s browsers, from a task (see the
  moduledoc), unless pushes are off or the member is around.
  """
  def notification_created(%User{} = user, %Notification{} = notification) do
    if enabled?() do
      run(fn -> push(user, notification) end)
    else
      :ok
    end
  end

  # Async in production; tests run it in their own process.
  defp run(fun) do
    if config()[:async] == false do
      fun.()
    else
      {:ok, _pid} = Task.Supervisor.start_child(__MODULE__.TaskSupervisor, fun)
      :ok
    end
  end

  defp push(user, notification) do
    user = Repo.get(User, user.id)
    subscriptions = if user && not around?(user), do: subscriptions(user), else: []

    payload =
      Jason.encode!(%{
        title: SiteSettings.get("title"),
        body: notification.subject,
        url: Notification.path(notification),
        tag: "notification-#{notification.id}"
      })

    Enum.each(subscriptions, &deliver(&1, payload))
  end

  defp around?(%User{push_only_when_away: false}), do: false
  defp around?(%User{last_seen_at: nil}), do: false

  defp around?(%User{last_seen_at: seen}),
    do: DateTime.diff(DateTime.utc_now(), seen, :minute) < @away_minutes

  @doc false
  def deliver(%Subscription{} = subscription, payload) do
    config = config()
    body = Encryption.encrypt(payload, subscription.p256dh, subscription.auth)

    headers = [
      {"authorization",
       VAPID.authorization(
         subscription.endpoint,
         config[:subject],
         config[:public_key],
         config[:private_key]
       )},
      {"content-encoding", "aes128gcm"},
      {"content-type", "application/octet-stream"},
      {"ttl", to_string(@ttl)},
      {"urgency", "normal"}
    ]

    case :hackney.request(:post, subscription.endpoint, headers, body, @http_options) do
      {:ok, status, _headers, _body} -> delivered(subscription, status)
      {:error, reason} -> Logger.warning("Web push failed: #{inspect(reason)}")
    end
  end

  defp delivered(subscription, status) when status in 200..299 do
    Subscription
    |> where([s], s.id == ^subscription.id)
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now(:second)])
  end

  # The browser unsubscribed (or the subscription expired).
  defp delivered(subscription, status) when status in [404, 410],
    do: Repo.delete_all(where(Subscription, id: ^subscription.id))

  defp delivered(_subscription, status),
    do: Logger.warning("Web push refused by the push service: HTTP #{status}")

  @doc "The export of `user`'s subscriptions (see `Firefly.Accounts.AccountExport`)."
  def export(%User{} = user) do
    for s <- subscriptions(user) do
      %{endpoint_host: URI.parse(s.endpoint).host, user_agent: s.user_agent, since: s.inserted_at}
    end
  end
end
