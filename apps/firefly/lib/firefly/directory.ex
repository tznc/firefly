defmodule Firefly.Directory do
  @moduledoc """
  The user directory (as Discourse's): every member with their stats over
  a period (`all`, `year`, `month`, `week`, `day`): likes received and
  given, topics (threads) started, replies, days visited (see
  `Firefly.Accounts.Visits`), posts read and topics viewed. Searchable by
  username or name, sortable by any stat, paginated.

  The stats aren't aggregated per page view: `refresh/0` recomputes them
  for everyone into `directory_items` (one row per user and period), and
  the scheduler (`Firefly.Moderation.TopicTimers.Scheduler`) runs it through
  `run_due/0` once the last refresh is over an hour old. Only published
  posts count, and likes on them. Members who left the directory or hid
  their profile (privacy settings) or deleted their account aren't listed; new members
  are, with no stats until the next refresh.
  """

  use Boundary, top_level?: true, check: [out: false], exports: []

  import Ecto.Query

  alias Firefly.Repo
  alias Firefly.Accounts.User
  alias Firefly.Directory.DirectoryItem

  @periods %{"all" => nil, "year" => 365, "month" => 30, "week" => 7, "day" => 1}

  @columns ~w(likes_received likes_given topic_count post_count days_visited posts_read topics_entered)

  @labels %{
    "likes_received" => "Likes received",
    "likes_given" => "Likes given",
    "topic_count" => "Topics",
    "post_count" => "Replies",
    "days_visited" => "Days visited",
    "posts_read" => "Posts read",
    "topics_entered" => "Topics viewed"
  }

  @refresh_seconds 3600

  # Held while refreshing, so several nodes don't all do it at once.
  @lock_key 4_216_301

  @doc "The periods, longest first."
  def periods, do: ~w(all year month week day)

  @doc "The stats, in display order."
  def columns, do: @columns

  @doc "A stat's column heading."
  def label(column), do: Map.fetch!(@labels, column)

  @doc """
  A page of the directory. `params` (string keys, all optional):
  `"period"`, `"order"` (a column), `"asc"` (`"true"` for ascending),
  `"name"` (a search on username or name) and `"page"`. Each entry is
  `%{user: user, stats: item}` (`stats` with zeros if not refreshed yet).
  """
  def page(params) do
    period = if Map.has_key?(@periods, params["period"]), do: params["period"], else: "all"
    order = if params["order"] in @columns, do: params["order"], else: "likes_received"
    direction = if params["asc"] == "true", do: :asc, else: :desc
    field = String.to_existing_atom(order)

    page =
      User
      |> where([u], is_nil(u.deleted_at) and not u.hide_from_directory and not u.hide_profile)
      |> join(:left, [u], d in DirectoryItem, on: d.user_id == u.id and d.period == ^period)
      |> search(params["name"])
      |> order_by([u, d], [{^direction, coalesce(field(d, ^field), 0)}, asc: u.username])
      |> select([u, d], %{user: u, stats: d})
      |> Repo.paginate(
        page: params["page"],
        page_size: Firefly.SiteSettings.get("directory_page_size")
      )

    entries =
      Enum.map(page.entries, fn entry ->
        %{entry | stats: entry.stats || %DirectoryItem{period: period}}
      end)

    %{page | entries: entries}
  end

  @doc "`user`'s all-time stats as of the last refresh (zeros before the first)."
  def user_stats(%User{id: user_id}) do
    Repo.get_by(DirectoryItem, user_id: user_id, period: "all") ||
      %DirectoryItem{period: "all", user_id: user_id}
  end

  # Postgres refuses NUL and invalid UTF-8 (anyone can put them in the
  # URL): they're dropped.
  defp search(query, name) when is_binary(name) do
    case name |> String.replace_invalid("") |> String.replace(<<0>>, "") |> String.trim() do
      "" ->
        query

      name ->
        pattern = "%" <> String.replace(name, ~r/[\\%_]/, "\\\\\\0") <> "%"
        where(query, [u], ilike(u.username, ^pattern) or ilike(u.name, ^pattern))
    end
  end

  defp search(query, _name), do: query

  @doc "When the stats were last refreshed, or nil."
  def refreshed_at do
    Repo.one(from(d in DirectoryItem, select: max(d.updated_at)))
  end

  @doc "Refreshes the stats if the last refresh is over an hour old (see the moduledoc)."
  def run_due do
    last = refreshed_at()

    if is_nil(last) or NaiveDateTime.diff(NaiveDateTime.utc_now(), last) > @refresh_seconds,
      do: refresh(),
      else: :ok
  end

  @doc "Recomputes every user's stats for every period."
  def refresh do
    {:ok, _} =
      Repo.transact(fn ->
        %{rows: [[locked?]]} = Repo.query!("SELECT pg_try_advisory_xact_lock($1)", [@lock_key])
        now = NaiveDateTime.utc_now()
        if locked?, do: Enum.each(@periods, &refresh(&1, now))
        {:ok, locked?}
      end)

    :ok
  end

  defp refresh({period, days}, now) do
    since = if days, do: NaiveDateTime.add(now, -days, :day), else: ~N[1970-01-01 00:00:00]

    Repo.query!(
      """
      WITH firsts AS (
        SELECT DISTINCT ON (thread_id) id FROM forums_posts ORDER BY thread_id, inserted_at, id
      ), posted AS (
        SELECT p.user_id, count(f.id) AS topics, count(*) - count(f.id) AS replies
        FROM forums_posts p LEFT JOIN firsts f ON f.id = p.id
        WHERE p.deleted_at IS NULL AND p.queued_at IS NULL AND p.inserted_at > $2
        GROUP BY p.user_id
      ), liked AS (
        SELECT l.user_id AS giver_id, p.user_id AS author_id
        FROM forums_post_likes l JOIN forums_posts p ON p.id = l.post_id
        WHERE p.deleted_at IS NULL AND p.queued_at IS NULL AND l.inserted_at > $2
      ), received AS (
        SELECT author_id AS user_id, count(*) AS n FROM liked GROUP BY author_id
      ), given AS (
        SELECT giver_id AS user_id, count(*) AS n FROM liked GROUP BY giver_id
      ), visits AS (
        SELECT user_id, count(*) AS days, sum(posts_read) AS read
        FROM user_visits WHERE visited_on > $4 GROUP BY user_id
      ), entered AS (
        SELECT user_id, count(*) AS n FROM forums_thread_reads WHERE updated_at > $2 GROUP BY user_id
      )
      INSERT INTO directory_items (period, user_id, likes_received, likes_given, topic_count,
        post_count, days_visited, posts_read, topics_entered, inserted_at, updated_at)
      SELECT $1, u.id, coalesce(received.n, 0), coalesce(given.n, 0), coalesce(posted.topics, 0),
        coalesce(posted.replies, 0), coalesce(visits.days, 0), coalesce(visits.read, 0),
        coalesce(entered.n, 0), $3, $3
      FROM forums_users u
      LEFT JOIN posted ON posted.user_id = u.id
      LEFT JOIN received ON received.user_id = u.id
      LEFT JOIN given ON given.user_id = u.id
      LEFT JOIN visits ON visits.user_id = u.id
      LEFT JOIN entered ON entered.user_id = u.id
      WHERE u.deleted_at IS NULL
      ON CONFLICT (period, user_id) DO UPDATE SET
        likes_received = EXCLUDED.likes_received, likes_given = EXCLUDED.likes_given,
        topic_count = EXCLUDED.topic_count, post_count = EXCLUDED.post_count,
        days_visited = EXCLUDED.days_visited, posts_read = EXCLUDED.posts_read,
        topics_entered = EXCLUDED.topics_entered, updated_at = EXCLUDED.updated_at
      """,
      [period, since, now, NaiveDateTime.to_date(since)]
    )
  end
end
