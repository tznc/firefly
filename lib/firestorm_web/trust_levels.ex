defmodule FirestormWeb.TrustLevels do
  @moduledoc """
  Trust levels, as Discourse's: every member has one, from 0 to 4, that
  unlocks more of the site as they take part.

    * 0, new user: posts may hold only a few links, images, attachments and
      mentions (the `new_user_max_*` site settings; see
      `FirestormWeb.Forums.SpamGuard`), and they can't start private
      conversations (`min_trust_to_send_messages`), flag
      (`min_trust_to_flag`) or edit wikis (`min_trust_to_edit_wiki`)
    * 1, basic user: those limits are lifted
    * 2, member: recognition (Discourse's invites and higher daily limits
      have no counterpart here)
    * 3, regular: renames, retags and recategorizes threads; a spam flag
      from a regular hides a new user's post at once (see
      `FirestormWeb.Flags`)
    * 4, leader (set by admins only): edits any post, makes posts wikis,
      pins and closes threads

  Admins pass every gate whatever their level. Posts by members below
  `approve_unless_trust_level` wait for approval (see
  `FirestormWeb.Forums.approval_required?/1`).

  Levels 1 to 3 are earned: `run_due/0` (run by
  `FirestormWeb.TopicTimers.Scheduler`, once an hour across nodes; see
  `FirestormWeb.JobRuns`) promotes confirmed members who meet the next
  level's requirements (site settings with Discourse's defaults: topics
  entered, posts read, days visited, likes given and received, topics
  replied to; time spent reading isn't tracked, so it isn't required) and
  demotes regulars who fell below 90% of level 3's, once the
  `tl3_promotion_min_duration` grace period has passed. Promotion notifies
  the member (`"promoted"`). Admins set a level, optionally locking it so
  the review leaves it alone (`set_level/4`, staff-logged); automatic
  changes are logged as the system's.

  Each level has an automatic group, `trust_level_0` to `trust_level_4`: a
  member is in their level's and every lower level's. A database trigger
  keeps the memberships in step with `trust_level`, so they can't be
  changed by hand (see `FirestormWeb.Groups`), but categories can be
  restricted to them and they can be made mentionable like any group.
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, JobRuns, Repo, SiteSettings, StaffLog}
  alias FirestormWeb.Forums.User
  alias FirestormWeb.Web.Paths

  @names %{0 => "new user", 1 => "basic user", 2 => "member", 3 => "regular", 4 => "leader"}

  @unlocks %{
    1 =>
      "New-user limits on links, images, attachments and mentions are lifted, and you can send private messages and flag posts.",
    2 => "Thanks for being part of the community.",
    3 =>
      "You can now rename, retag and move threads to other categories, and your spam flags on new users' posts hide them at once.",
    4 => "You can now edit any post, make posts wikis, and pin and close threads."
  }

  # Discourse's caps on the share of recent threads and posts a regular
  # must have read.
  @topics_viewed_cap 500
  @posts_read_cap 20_000

  # A regular stays one until below this share of a requirement.
  @retention 0.9

  @review_seconds 3600
  @batch 500

  @doc "Every level, lowest first."
  def levels, do: 0..4

  @doc ~S'The level as people read it: "member".'
  def name(level), do: Map.fetch!(@names, level)

  @doc ~S'The level with its number: "member (trust level 2)".'
  def title(level), do: "#{name(level)} (trust level #{level})"

  @doc "The name of the level's automatic group."
  def group_name(level), do: "trust_level_#{level}"

  @doc "Whether `name` is an automatic trust level group's."
  def group?(name) when is_binary(name), do: name =~ ~r/^trust_level_[0-4]$/
  def group?(_name), do: false

  @doc "Whether `user` is at `level` or above (admins always are)."
  def at_least?(nil, _level), do: false

  def at_least?(%User{trust_level: trust_level} = user, level),
    do: trust_level >= level or Forums.admin?(user)

  @doc "Whether `user` reaches the trust level a site setting (`key`) asks for."
  def allowed?(user, key), do: at_least?(user, SiteSettings.get(key))

  @doc "Whether new-user limits apply to `user`: trust level 0, not an admin."
  def new_user?(%User{} = user), do: not at_least?(user, 1)

  ## Admins

  @doc """
  Sets `user`'s level as `admin`, and locks it there (`lock?`) or unlocks
  it (so the review may change it again). Staff-logged; a promotion
  notifies the member.
  """
  def set_level(%User{} = user, level, lock?, %User{} = admin) when level in 0..4 do
    locked = if lock?, do: level

    {:ok, updated} =
      Repo.transact(fn ->
        updated = change_level(user, level, locked: locked)

        StaffLog.record(admin, "user.trust_level", user, %{
          username: user.username,
          from: user.trust_level,
          to: level,
          locked: lock?
        })

        {:ok, updated}
      end)

    if level > user.trust_level, do: notify_promotion(updated)
    {:ok, updated}
  end

  defp change_level(user, level, opts) do
    changes = [
      manual_locked_trust_level: Keyword.get(opts, :locked, user.manual_locked_trust_level)
    ]

    changes =
      if level == user.trust_level,
        do: changes,
        else: [trust_level: level, trust_level_changed_at: DateTime.utc_now(:second)] ++ changes

    {:ok, updated} = user |> Ecto.Changeset.change(changes) |> Repo.update()
    updated
  end

  defp notify_promotion(user) do
    {:ok, _} =
      Forums.notify(user, %{
        kind: "promoted",
        subject: "You're now a #{title(user.trust_level)}",
        body: @unlocks[user.trust_level],
        url: Paths.user_url(user)
      })
  end

  ## The review

  @doc "Reviews every member's level, if an hour has passed since the last review."
  def run_due do
    if JobRuns.claim("trust_levels", @review_seconds), do: review(), else: :ok
  end

  @doc "Promotes and demotes members as their activity warrants (see the moduledoc)."
  def review do
    User
    |> where([u], is_nil(u.deleted_at) and is_nil(u.plugin_bot))
    |> where([u], is_nil(u.manual_locked_trust_level) and u.trust_level < 4)
    |> where([u], not is_nil(u.confirmed_at))
    |> order_by(:id)
    |> Repo.all()
    |> Enum.chunk_every(@batch)
    |> Enum.each(&review_batch/1)
  end

  defp review_batch(users) do
    stats = stats(users)
    totals = totals()

    for user <- users do
      case target(user, Map.fetch!(stats, user.id), totals) do
        level when level == user.trust_level -> :ok
        level -> apply_review(user, level)
      end
    end
  end

  # The level the user should be at.
  defp target(%User{trust_level: 3} = user, stats, totals) do
    cond do
      met?(3, stats, totals, @retention) -> 3
      in_grace?(user) -> 3
      true -> 2
    end
  end

  defp target(%User{trust_level: level}, stats, totals) do
    (level + 1)..3//1
    |> Enum.take_while(&met?(&1, stats, totals, 1.0))
    |> List.last(level)
  end

  defp in_grace?(%User{trust_level_changed_at: nil}), do: false

  defp in_grace?(%User{trust_level_changed_at: at}) do
    days = SiteSettings.get("tl3_promotion_min_duration")
    DateTime.diff(DateTime.utc_now(), at, :day) < days
  end

  defp met?(level, stats, totals, share) do
    level
    |> requirements(stats, totals)
    |> Enum.all?(fn %{have: have, need: need, max?: max?} ->
      if max?, do: have <= need, else: have >= need * share
    end)
  end

  defp apply_review(user, level) do
    {:ok, updated} =
      Repo.transact(fn ->
        updated = change_level(user, level, [])

        StaffLog.record_system("user.trust_level", user, %{
          username: user.username,
          from: user.trust_level,
          to: level,
          automatic: true
        })

        {:ok, updated}
      end)

    if level > user.trust_level, do: notify_promotion(updated)
  end

  ## Requirements

  @doc """
  What `user` needs for the next level they can earn (up to 3, or to keep
  3), as `{level, requirements}`: each requirement has a `label`, what the
  member `have`s, what they `need`, `max?` (a limit rather than a goal)
  and `met?`. Nil for leaders and locked levels.
  """
  def progress(%User{trust_level: 4}), do: nil
  def progress(%User{manual_locked_trust_level: locked}) when is_integer(locked), do: nil

  def progress(%User{} = user) do
    level = min(user.trust_level + 1, 3)
    stats = Map.fetch!(stats([user]), user.id)

    requirements =
      for r <- requirements(level, stats, totals()) do
        Map.put(r, :met?, if(r.max?, do: r.have <= r.need, else: r.have >= r.need))
      end

    {level, requirements}
  end

  defp requirements(1, stats, _totals) do
    [
      need("Topics entered", stats.topics_entered, "tl1_requires_topics_entered"),
      need("Posts read", stats.posts_read, "tl1_requires_read_posts")
    ]
  end

  defp requirements(2, stats, _totals) do
    [
      need("Topics entered", stats.topics_entered, "tl2_requires_topics_entered"),
      need("Posts read", stats.posts_read, "tl2_requires_read_posts"),
      need("Days visited", stats.days_visited, "tl2_requires_days_visited"),
      need("Likes received", stats.likes_received, "tl2_requires_likes_received"),
      need("Likes given", stats.likes_given, "tl2_requires_likes_given"),
      need("Topics replied to", stats.topics_replied_to, "tl2_requires_topic_reply_count")
    ]
  end

  defp requirements(3, stats, totals) do
    topics = min(totals.topics, @topics_viewed_cap)
    posts = min(totals.posts, @posts_read_cap)

    [
      need("Days visited (period)", stats.period_days_visited, "tl3_requires_days_visited"),
      need(
        "Topics replied to (period)",
        stats.period_topics_replied_to,
        "tl3_requires_topics_replied_to"
      ),
      share(
        "Topics viewed (period)",
        stats.period_topics_entered,
        topics,
        "tl3_requires_topics_viewed"
      ),
      share("Posts read (period)", stats.period_posts_read, posts, "tl3_requires_posts_read"),
      need(
        "Topics viewed (all time)",
        stats.topics_entered,
        "tl3_requires_topics_viewed_all_time"
      ),
      need("Posts read (all time)", stats.posts_read, "tl3_requires_posts_read_all_time"),
      need("Likes given (period)", stats.period_likes_given, "tl3_requires_likes_given"),
      need("Likes received (period)", stats.period_likes_received, "tl3_requires_likes_received"),
      %{
        label: "Flagged posts (period)",
        have: stats.period_flagged_posts,
        need: SiteSettings.get("tl3_requires_max_flagged"),
        max?: true
      },
      %{label: "Silenced or suspended", have: stats.penalized, need: 0, max?: true}
    ]
  end

  defp need(label, have, key),
    do: %{label: label, have: have, need: SiteSettings.get(key), max?: false}

  defp share(label, have, total, key),
    do: %{label: label, have: have, need: ceil(total * SiteSettings.get(key) / 100), max?: false}

  # The threads and published posts made in the level 3 period.
  defp totals do
    since = period_start()

    %{
      topics: Repo.aggregate(where(Forums.Thread, [t], t.inserted_at > ^since), :count),
      posts:
        Repo.aggregate(
          where(
            Forums.Post,
            [p],
            p.inserted_at > ^since and is_nil(p.deleted_at) and is_nil(p.queued_at)
          ),
          :count
        )
    }
  end

  defp period_start,
    do: NaiveDateTime.add(NaiveDateTime.utc_now(), -SiteSettings.get("tl3_time_period"), :day)

  @stats ~w(days_visited posts_read topics_entered likes_given likes_received topics_replied_to
            period_days_visited period_posts_read period_topics_entered period_likes_given
            period_likes_received period_topics_replied_to period_flagged_posts penalized)a

  # Each user's activity, all time and in the level 3 period, by user id.
  defp stats(users) do
    ids = Enum.map(users, & &1.id)
    since = period_start()

    %{rows: rows} =
      Repo.query!(
        """
        WITH visits AS (
          SELECT user_id, count(*) AS days, sum(posts_read)::bigint AS read,
            count(*) FILTER (WHERE visited_on > $3) AS period_days,
            coalesce(sum(posts_read) FILTER (WHERE visited_on > $3), 0)::bigint AS period_read
          FROM user_visits WHERE user_id = ANY($1) GROUP BY user_id
        ), entered AS (
          SELECT user_id, count(*) AS n, count(*) FILTER (WHERE updated_at > $2) AS period
          FROM forums_thread_reads WHERE user_id = ANY($1) GROUP BY user_id
        ), given AS (
          SELECT user_id, count(*) AS n, count(*) FILTER (WHERE inserted_at > $2) AS period
          FROM forums_post_likes WHERE user_id = ANY($1) GROUP BY user_id
        ), received AS (
          SELECT p.user_id, count(*) AS n, count(*) FILTER (WHERE l.inserted_at > $2) AS period
          FROM forums_post_likes l JOIN forums_posts p ON p.id = l.post_id
          WHERE p.user_id = ANY($1) AND p.deleted_at IS NULL GROUP BY p.user_id
        ), firsts AS (
          SELECT DISTINCT ON (thread_id) thread_id, user_id FROM forums_posts
          WHERE thread_id IN (SELECT thread_id FROM forums_posts WHERE user_id = ANY($1))
          ORDER BY thread_id, inserted_at, id
        ), replied AS (
          SELECT p.user_id, count(DISTINCT p.thread_id) AS n,
            count(DISTINCT p.thread_id) FILTER (WHERE p.inserted_at > $2) AS period
          FROM forums_posts p JOIN firsts f ON f.thread_id = p.thread_id AND f.user_id <> p.user_id
          WHERE p.user_id = ANY($1) AND p.deleted_at IS NULL AND p.queued_at IS NULL
          GROUP BY p.user_id
        ), flagged AS (
          SELECT p.user_id, count(DISTINCT p.id) AS n
          FROM forums_post_flags f JOIN forums_posts p ON p.id = f.post_id
          WHERE p.user_id = ANY($1) AND f.status = 'agreed' AND f.inserted_at > $2
          GROUP BY p.user_id
        )
        SELECT u.id, coalesce(visits.days, 0), coalesce(visits.read, 0), coalesce(entered.n, 0),
          coalesce(given.n, 0), coalesce(received.n, 0), coalesce(replied.n, 0),
          coalesce(visits.period_days, 0), coalesce(visits.period_read, 0),
          coalesce(entered.period, 0), coalesce(given.period, 0), coalesce(received.period, 0),
          coalesce(replied.period, 0), coalesce(flagged.n, 0),
          (u.silenced_until > now() OR u.suspended_until > now())::int
        FROM forums_users u
        LEFT JOIN visits ON visits.user_id = u.id
        LEFT JOIN entered ON entered.user_id = u.id
        LEFT JOIN given ON given.user_id = u.id
        LEFT JOIN received ON received.user_id = u.id
        LEFT JOIN replied ON replied.user_id = u.id
        LEFT JOIN flagged ON flagged.user_id = u.id
        WHERE u.id = ANY($1)
        """,
        [ids, since, NaiveDateTime.to_date(since)]
      )

    Map.new(rows, fn [id | values] ->
      {id, @stats |> Enum.zip(Enum.map(values, &(&1 || 0))) |> Map.new()}
    end)
  end
end
