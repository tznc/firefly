defmodule Firefly.Analytics do
  @moduledoc """
  The Analytics context: privacy-respecting, first-party traffic counts, as
  Discourse's. No cookies beyond the session, no third parties, and no IP
  address is ever stored.

  What it counts, per day:

    * page views by kind (`kinds/0`): logged-in, anonymous, crawler (by
      user agent, see `crawler?/1`) and API requests;
    * topic views: each viewer counted once per thread and day. A
      logged-in viewer is their user id; an anonymous one a hash of their
      address and user agent salted with a random value made for the day
      (`analytics_salts`) and deleted once the day is over, so the hash
      can't be traced back to an address afterwards. Each thread's total is
      in `forums_threads.views`;
    * referrer domains of visits from other sites;
    * clicks on links in posts, per post and URL (no date), shown next to
      the links. A click only counts if the post links to that URL.

  Requests asking not to be tracked (`Do Not Track` or `Sec-GPC`) still
  count in the page view totals, but nothing else about them is recorded.
  The whole thing is off with the `analytics` site setting.

  The write path is cheap: everything is counted in memory, in an ETS
  table (`Firefly.Analytics.Buffer`), and written to the database in
  batches every few seconds (and when the app stops), adding to the
  day's counts, so any number of nodes can flush.
  """

  use Boundary, top_level?: true, check: [out: false], exports: []

  import Ecto.Query

  alias Firefly.{JobRuns, Repo, SiteSettings}
  alias Firefly.Analytics.Buffer
  alias Firefly.Discussion.{Post, Thread}

  @kinds ~w(logged_in anonymous crawler api)
  @labels %{
    "logged_in" => "Logged in",
    "anonymous" => "Anonymous",
    "crawler" => "Crawlers",
    "api" => "API"
  }

  @crawlers ~r/bot\b|bot\/|crawl|spider|slurp|archiver|bingpreview|mediapartners|facebookexternalhit|embedly|quora link preview|pinterest|vkshare|whatsapp|telegram|skypeuripreview|preview|headless|lighthouse|curl\/|wget\/|python-requests|python-urllib|go-http-client|okhttp|java\/|libwww|httpclient|scrapy/i
  @max_url 2000

  @doc "The page view kinds, in display order."
  def kinds, do: @kinds

  @doc "A page view kind's label."
  def label(kind), do: Map.fetch!(@labels, kind)

  @doc "Whether analytics are on (the `analytics` site setting)."
  def enabled?, do: SiteSettings.get("analytics")

  @doc "Whether `user_agent` is a crawler's (or missing, as scripts' often are)."
  def crawler?(user_agent) when is_binary(user_agent),
    do: String.trim(user_agent) == "" or Regex.match?(@crawlers, user_agent)

  def crawler?(_user_agent), do: true

  @doc """
  The kind of a page view by `user` (or nil) with `user_agent`: a crawler
  is one whatever its session.
  """
  def kind(user, user_agent) do
    cond do
      crawler?(user_agent) -> "crawler"
      user -> "logged_in"
      true -> "anonymous"
    end
  end

  ## Counting (in memory, see the moduledoc)

  @doc "Counts a page view of `kind`."
  def page_view(kind) when kind in @kinds, do: Buffer.increment({:page, today(), kind})

  @doc """
  Counts a visit referred by `url` (a `Referer`), unless it's from `own_host`
  or isn't a web page. `www.` is dropped from the domain.
  """
  def referrer(url, own_host) when is_binary(url) do
    with %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(url),
         domain = host |> String.downcase() |> String.replace_prefix("www.", ""),
         true <- domain != "" and domain != String.replace_prefix(own_host, "www.", "") do
      Buffer.increment({:referrer, today(), String.slice(domain, 0, 255)})
    else
      _ -> :ok
    end
  end

  def referrer(_url, _own_host), do: :ok

  @doc """
  Counts a view of the thread with id `thread_id` by `viewer`: `{:user, id}`
  or `{:anonymous, ip, user_agent}` (`ip` a tuple or string). Each viewer
  counts once a day.
  """
  def topic_view(thread_id, viewer) when is_integer(thread_id),
    do: Buffer.put({:view, today(), thread_id, viewer_key(viewer, today())})

  @doc """
  Counts a click on `url` in the post with id `post_id` (checked against the
  post when it's written).
  """
  def link_click(post_id, url)
      when is_integer(post_id) and is_binary(url) and byte_size(url) <= @max_url do
    if String.starts_with?(url, ["http://", "https://"]),
      do: Buffer.increment({:click, post_id, url}),
      else: :ok
  end

  def link_click(_post_id, _url), do: :ok

  defp viewer_key({:user, id}, _date), do: "u:#{id}"

  defp viewer_key({:anonymous, ip, user_agent}, date) do
    ip = if is_tuple(ip), do: ip |> :inet.ntoa() |> to_string(), else: to_string(ip)
    digest = :crypto.hash(:sha256, [salt(date), ip, 0, to_string(user_agent)])
    "a:" <> Base.url_encode64(binary_part(digest, 0, 16), padding: false)
  end

  # The day's random salt, the same on every node: made by whichever node
  # needs it first.
  defp salt(date) do
    case :persistent_term.get({__MODULE__, :salt}, nil) do
      {^date, salt} ->
        salt

      _other ->
        Repo.query!(
          "INSERT INTO analytics_salts (date, salt) VALUES ($1, $2) ON CONFLICT DO NOTHING",
          [date, :crypto.strong_rand_bytes(32)]
        )

        %{rows: [[salt]]} =
          Repo.query!("SELECT salt FROM analytics_salts WHERE date = $1", [date])

        :persistent_term.put({__MODULE__, :salt}, {date, salt})
        salt
    end
  end

  defp today, do: Date.utc_today()

  ## Writing

  @doc """
  Writes what's been counted in memory to the database. Called every few
  seconds by `Firefly.Analytics.Buffer`.
  """
  def flush do
    entries = Buffer.take()

    {pages, rest} = Enum.split_with(entries, &match?({{:page, _, _}, _}, &1))
    {referrers, rest} = Enum.split_with(rest, &match?({{:referrer, _, _}, _}, &1))
    {clicks, views} = Enum.split_with(rest, &match?({{:click, _, _}, _}, &1))

    write_counts("analytics_page_views", :kind, for({{:page, d, k}, n} <- pages, do: {d, k, n}))

    write_counts(
      "analytics_referrers",
      :domain,
      for({{:referrer, d, domain}, n} <- referrers, do: {d, domain, n})
    )

    write_clicks(for {{:click, post_id, url}, n} <- clicks, do: {post_id, url, n})
    write_views(for {{:view, d, thread_id, viewer}, _} <- views, do: {d, thread_id, viewer})
    :ok
  end

  defp write_counts(_table, _field, []), do: :ok

  defp write_counts(table, field, rows) do
    Repo.insert_all(
      table,
      Enum.map(rows, fn {date, key, n} -> %{:date => date, field => key, :count => n} end),
      on_conflict: increment(table),
      conflict_target: [:date, field]
    )
  end

  # Adds to the count already there.
  defp increment(table),
    do: from(r in table, update: [set: [count: fragment("? + EXCLUDED.count", r.count)]])

  # Only clicks on links the post has.
  defp write_clicks([]), do: :ok

  defp write_clicks(rows) do
    ids = Enum.uniq(Enum.map(rows, &elem(&1, 0)))
    bodies = Map.new(Repo.all(from(p in Post, where: p.id in ^ids, select: {p.id, p.body})))

    rows =
      for {post_id, url, n} <- rows, links?(bodies[post_id], url) do
        %{post_id: post_id, url: url, count: n}
      end

    if rows != [] do
      Repo.insert_all("analytics_link_clicks", rows,
        on_conflict: increment("analytics_link_clicks"),
        conflict_target: [:post_id, :url]
      )
    end
  end

  defp links?(nil, _url), do: false

  defp links?(body, url),
    do:
      String.contains?(body, url) or String.contains?(body, String.trim_trailing(url, "/")) or
        String.contains?(body, String.replace(url, "&amp;", "&"))

  # New viewers (the insert skips those already counted today) add to the
  # threads' daily and total views.
  defp write_views([]), do: :ok

  defp write_views(rows) do
    ids = Enum.uniq(Enum.map(rows, &elem(&1, 1)))
    existing = MapSet.new(Repo.all(from(t in Thread, where: t.id in ^ids, select: t.id)))

    rows =
      for {date, thread_id, viewer} <- rows,
          thread_id in existing,
          do: %{date: date, thread_id: thread_id, viewer: viewer}

    if rows != [], do: Repo.transact(fn -> {:ok, add_views(rows)} end)
  end

  defp add_views(rows) do
    {_, new} =
      Repo.insert_all("analytics_topic_viewers", rows,
        on_conflict: :nothing,
        returning: [:date, :thread_id]
      )

    counts = Enum.frequencies_by(new, &{&1.date, &1.thread_id})
    write_counts("analytics_topic_views", :thread_id, for({{d, t}, n} <- counts, do: {d, t, n}))

    for {thread_id, n} <- Enum.frequencies_by(new, & &1.thread_id) do
      Repo.update_all(from(t in Thread, where: t.id == ^thread_id), inc: [views: n])
    end

    length(new)
  end

  @doc """
  Drops what's only needed for the day (viewers counted today, the day's
  salt) once it's over. Run by the scheduler
  (`Firefly.Moderation.TopicTimers.Scheduler`), once an hour across nodes.
  """
  def run_due do
    if JobRuns.claim("analytics.prune", 3600) do
      today = today()
      Repo.delete_all(from(v in "analytics_topic_viewers", where: v.date < ^today))
      Repo.delete_all(from(s in "analytics_salts", where: s.date < ^today))
    end

    :ok
  end

  ## Reading

  @doc "Click counts of the links in `posts`: `%{post_id => %{url => count}}`."
  def link_clicks(posts) do
    ids = Enum.map(posts, & &1.id)

    query =
      from(c in "analytics_link_clicks",
        where: c.post_id in ^ids and c.count > 0,
        select: {c.post_id, c.url, c.count}
      )

    query
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_, url, count} -> {url, count} end)
    |> Map.new(fn {post_id, counts} -> {post_id, Map.new(counts)} end)
  end

  @doc "Page views per day and kind between `from` and `to` (dates, inclusive): `[{date, kind, count}]`."
  def page_views(%Date{} = from, %Date{} = to) do
    Repo.all(
      from(p in "analytics_page_views",
        where: p.date >= ^from and p.date <= ^to,
        order_by: [p.date, p.kind],
        select: {p.date, p.kind, p.count}
      )
    )
  end

  @doc "The `limit` domains that referred most visits between `from` and `to`: `[{domain, count}]`."
  def top_referrers(%Date{} = from, %Date{} = to, limit \\ 20) do
    Repo.all(
      from(r in "analytics_referrers",
        where: r.date >= ^from and r.date <= ^to,
        group_by: r.domain,
        order_by: [desc: sum(r.count), asc: r.domain],
        limit: ^limit,
        select: {r.domain, type(sum(r.count), :integer)}
      )
    )
  end

  @doc "The `limit` threads viewed most between `from` and `to`: `[{thread, views}]`."
  def top_topics(%Date{} = from, %Date{} = to, limit \\ 20) do
    Repo.all(
      from(v in "analytics_topic_views",
        join: t in Thread,
        on: t.id == v.thread_id,
        where: v.date >= ^from and v.date <= ^to,
        group_by: t.id,
        order_by: [desc: sum(v.count), asc: t.id],
        limit: ^limit,
        select: {t, type(sum(v.count), :integer)}
      )
    )
  end
end
