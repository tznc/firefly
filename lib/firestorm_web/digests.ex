defmodule FirestormWeb.Digests do
  @moduledoc """
  Digest emails, as Discourse's summary emails: members who haven't visited
  in a while get a summary of what they missed, as often as they choose
  (`digest_frequency`: never, daily, weekly, every two weeks or monthly;
  nil follows the `default_digest_frequency` site setting, weekly).

  A digest goes out only while the member is away: they haven't been seen
  (see `FirestormWeb.Visits`) and haven't had a digest for their period.
  It covers what happened since the later of the two: the most active
  threads started since then that they'd see in their lists (readable
  categories only, leaving out what they muted and threads by people they
  ignore), how many new posts there were, the most liked replies, and
  their unread notifications. With nothing new, nothing is sent.

  Only confirmed, active (not suspended or deleted) accounts with an email
  get digests, and none while the `digests_enabled` site setting is off.
  `run_due/0` runs from the scheduler (`FirestormWeb.TopicTimers.Scheduler`)
  every 15 minutes across nodes (see `FirestormWeb.JobRuns`), in batches.
  Each member is claimed by setting `last_digest_at` in one conditional
  update before their digest is built, so two nodes never send the same
  one.

  Every digest has a one-click unsubscribe link (a signed token, also in
  the `List-Unsubscribe` header, RFC 8058) that turns digests off.
  """

  import Ecto.Query
  require Logger

  alias FirestormWeb.{Emails, Forums, JobRuns, Mailer, Repo, SiteSettings}
  alias FirestormWeb.Forums.User
  alias FirestormWeb.Web.Endpoint

  @frequencies [
    {"Never", "never", nil},
    {"Daily", "daily", 1},
    {"Weekly", "weekly", 7},
    {"Every two weeks", "biweekly", 14},
    {"Monthly", "monthly", 30}
  ]

  @run_seconds 900
  @batch 200
  @salt "digest unsubscribe"
  # Unsubscribe links work for a year: digests linger in inboxes.
  @token_max_age 365 * 24 * 3600

  @doc "The frequencies a member can pick."
  def frequencies, do: Enum.map(@frequencies, &elem(&1, 1))

  @doc "The frequencies as select options."
  def frequency_options,
    do: Enum.map(@frequencies, fn {label, value, _days} -> {label, value} end)

  @doc "`user`'s frequency: their choice, or the site's default."
  def frequency(%User{digest_frequency: nil}), do: SiteSettings.get("default_digest_frequency")
  def frequency(%User{digest_frequency: frequency}), do: frequency

  @doc "A frequency as people read it."
  def label(frequency) do
    Enum.find_value(@frequencies, fn {label, value, _days} -> value == frequency && label end)
  end

  ## Sending

  @doc "Sends the digests that are due, if 15 minutes have passed since the last run."
  def run_due do
    if SiteSettings.get("digests_enabled") and JobRuns.claim("digests", @run_seconds),
      do: send_due(),
      else: :ok
  end

  @doc "Sends a digest to every member it's due for (a batch per frequency). Returns how many."
  def send_due(now \\ DateTime.utc_now(:second)) do
    default = SiteSettings.get("default_digest_frequency")

    for {_label, frequency, days} <- @frequencies, days, reduce: 0 do
      sent -> sent + (now |> due(frequency, days, default) |> Enum.count(&deliver(&1, now, days)))
    end
  end

  defp due(now, frequency, days, default) do
    cutoff = DateTime.add(now, -days, :day)

    User
    |> where([u], coalesce(u.digest_frequency, ^default) == ^frequency)
    |> eligible()
    |> where([u], is_nil(u.last_seen_at) or u.last_seen_at < ^cutoff)
    |> where([u], is_nil(u.last_digest_at) or u.last_digest_at < ^cutoff)
    |> where([u], u.inserted_at < ^DateTime.to_naive(cutoff))
    |> order_by([u], asc_nulls_first: u.last_digest_at, asc: u.id)
    |> limit(@batch)
    |> Repo.all()
  end

  defp eligible(query) do
    now = DateTime.utc_now()

    query
    |> where([u], not is_nil(u.confirmed_at) and not is_nil(u.email))
    |> where([u], is_nil(u.deleted_at) and is_nil(u.plugin_bot))
    |> where([u], is_nil(u.suspended_until) or u.suspended_until < ^now)
  end

  # Claims the member's digest (unless another node just did), then sends
  # it if there's anything to tell.
  defp deliver(user, now, days) do
    cutoff = DateTime.add(now, -days, :day)

    {claimed, _} =
      User
      |> where([u], u.id == ^user.id)
      |> where([u], is_nil(u.last_digest_at) or u.last_digest_at < ^cutoff)
      |> Repo.update_all(set: [last_digest_at: now])

    with 1 <- claimed,
         %{} = digest <- build(user) do
      user |> Emails.digest(digest, unsubscribe_url(user)) |> Mailer.deliver_now()
      true
    else
      _nothing -> false
    end
  rescue
    error ->
      Logger.error("Digest for user #{user.id} failed: " <> Exception.message(error))
      false
  end

  @doc """
  What `user`'s digest would say, or nil if there's nothing new: `since`,
  `threads` (popular new threads), `new_posts`, `replies` (most liked) and
  `notifications` (`{unread count, the latest few}`).
  """
  def build(%User{} = user) do
    since = since(user)
    threads = Forums.popular_new_threads(user, since, 5)

    unread =
      user
      |> Forums.notifications_for()
      |> Enum.filter(&is_nil(&1.read_at))

    if threads == [] and unread == [] do
      nil
    else
      %{
        since: since,
        threads: threads,
        new_posts: Forums.new_posts_count(user, since),
        replies: Forums.top_replies(user, since, 3),
        notifications: {length(unread), Enum.take(unread, 5)}
      }
    end
  end

  # Since the member was last here or last had a digest, whichever is later.
  defp since(user) do
    [user.last_seen_at, user.last_digest_at, DateTime.from_naive!(user.inserted_at, "Etc/UTC")]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime)
    |> DateTime.to_naive()
  end

  ## Unsubscribing

  @doc "The one-click link that turns `user`'s digests off."
  def unsubscribe_url(%User{} = user),
    do:
      FirestormWeb.Web.Paths.digest_unsubscribe_url(Phoenix.Token.sign(Endpoint, @salt, user.id))

  @doc "The user an unsubscribe token is for: `{:ok, user}` or `{:error, :invalid}`."
  def verify(token) do
    with {:ok, id} <- Phoenix.Token.verify(Endpoint, @salt, token, max_age: @token_max_age),
         %User{deleted_at: nil} = user <- Repo.get(User, id) do
      {:ok, user}
    else
      _invalid -> {:error, :invalid}
    end
  end

  @doc "Turns digests off for the user the token is for."
  def unsubscribe(token) do
    with {:ok, user} <- verify(token) do
      user |> Ecto.Changeset.change(digest_frequency: "never") |> Repo.update()
    end
  end
end
