defmodule Firefly.Embedding do
  @moduledoc """
  The Embedding context: topics as blog comments, as Discourse's embedding.

  Admins list the sites allowed to embed (`Firefly.Embedding.EmbeddableHost`,
  at `/staff/embedding`). A page on one of them includes Firefly's
  `embed.js` with a config (`window.FireflyEmbed = {fireflyUrl, embedUrl,
  topicId}`), which adds an iframe of `/embed/comments`: the topic's
  latest replies and links to continue the discussion or reply. Only the
  configured sites may frame it (`frame_ancestors/0`), and only their
  pages get topics.

  A page's topic is made the first time it's viewed (`topic_for_url/1`):
  the page is fetched through the server-side request forgery guard of
  link previews (`Firefly.Rendering.LinkPreviews.Fetcher`: public
  addresses only, every redirect checked), its title and excerpt taken
  from OpenGraph tags, else its `<title>` and first paragraphs, and the
  topic posted by the `embed_username` member (else the first admin) in
  the site's category (else the first one), tagged with the site's tag,
  linking back to the page. With an `embed_feed_url` (RSS or Atom),
  `run_due/0` makes topics for the feed's new entries once an hour, from
  the entries' titles and summaries. Nothing is made while the site is
  read-only.
  """

  use Boundary, top_level?: true, check: [out: false], exports: [EmbeddableHost, TopicEmbed]

  import Ecto.Query

  require Logger

  alias Firefly.{Accounts, Backups, Discussion, JobRuns, Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Post, Thread}
  alias Firefly.Embedding.{EmbeddableHost, TopicEmbed}
  alias Firefly.Moderation.StaffLog
  alias Firefly.Rendering.LinkPreviews.{Fetcher, Parser}

  @feed_types ~w(application/rss+xml application/atom+xml application/xml text/xml)
  @max_feed_topics 20

  ## Hosts

  @doc "The embeddable hosts, by name."
  def list_hosts, do: Repo.all(from(h in EmbeddableHost, order_by: h.host, preload: :category))

  def get_host(id), do: Repo.get(EmbeddableHost, id)

  @doc "A changeset for the host form."
  def change_host(host \\ %EmbeddableHost{}, attrs \\ %{}),
    do: EmbeddableHost.changeset(host, attrs)

  @doc "Adds an embeddable host as `admin`."
  def create_host(attrs, %User{} = admin) do
    Repo.transact(fn ->
      with {:ok, host} <- Repo.insert(EmbeddableHost.changeset(%EmbeddableHost{}, attrs)) do
        StaffLog.record(admin, "embed_host.create", {"embed_host", host.id}, %{host: host.host})
        {:ok, host}
      end
    end)
  end

  @doc "Removes an embeddable host as `admin` (its topics stay)."
  def delete_host(%EmbeddableHost{} = host, %User{} = admin) do
    {:ok, _} =
      Repo.transact(fn ->
        Repo.delete!(host)
        StaffLog.record(admin, "embed_host.delete", {"embed_host", host.id}, %{host: host.host})
        {:ok, host}
      end)

    :ok
  end

  @doc "The host `url` may embed from, or nil: its host and port, and an allowed path."
  def host_for(url) when is_binary(url) do
    with %URI{scheme: scheme, host: host, port: port, path: path}
         when scheme in ["http", "https"] and is_binary(host) <- URI.parse(url),
         %EmbeddableHost{} = embeddable <- Repo.get_by(EmbeddableHost, host: host_key(host, port)),
         true <- path_allowed?(embeddable, path || "/") do
      embeddable
    else
      _ -> nil
    end
  end

  def host_for(_url), do: nil

  defp host_key(host, port) when port in [nil, 80, 443], do: String.downcase(host)
  defp host_key(host, port), do: "#{String.downcase(host)}:#{port}"

  defp path_allowed?(%EmbeddableHost{allowed_paths: []}, _path), do: true

  defp path_allowed?(%EmbeddableHost{allowed_paths: paths}, path),
    do: Enum.any?(paths, &String.starts_with?(path, &1))

  @doc """
  The origins that may frame the comments (a CSP `frame-ancestors` source
  list): each host over http and https.
  """
  def frame_ancestors do
    for host <- Repo.all(from(h in EmbeddableHost, select: h.host)),
        scheme <- ~w(https http),
        do: "#{scheme}://#{host}"
  end

  ## Topics

  @doc "`url` without its fragment: the key pages are known by."
  def normalize_url(url), do: url |> URI.parse() |> Map.put(:fragment, nil) |> URI.to_string()

  @doc """
  The topic discussing the page at `url`, made now if it has none:
  `{:ok, thread}` or `{:error, reason}` (`:not_allowed` when the page
  isn't on an embeddable host, `:read_only`, `:no_user`, or why the page
  couldn't be fetched).
  """
  def topic_for_url(url) when is_binary(url) do
    url = normalize_url(url)

    case Repo.get_by(TopicEmbed, embed_url: url) do
      %TopicEmbed{thread_id: id} ->
        thread_or_error(id)

      nil ->
        case host_for(url) do
          nil -> {:error, :not_allowed}
          host -> create_from_page(url, host)
        end
    end
  end

  def topic_for_url(_url), do: {:error, :not_allowed}

  defp thread_or_error(id) do
    case Discussion.get_thread(id) do
      nil -> {:error, :not_found}
      thread -> {:ok, thread}
    end
  end

  defp create_from_page(url, host) do
    with :ok <- writable(),
         {:ok, user} <- embed_user(),
         {:ok, page} <- fetch_page(url) do
      create_topic(url, host, user, page.title || url, page.excerpt)
    end
  end

  defp writable, do: if(Backups.read_only?(), do: {:error, :read_only}, else: :ok)

  @doc "Who posts the topics: the `embed_username` member, else the first admin."
  def embed_user do
    username = String.trim(SiteSettings.get("embed_username"))

    user =
      if username != "",
        do: Accounts.get_user_by_username(username),
        else: first_admin()

    if user, do: {:ok, user}, else: {:error, :no_user}
  end

  defp first_admin do
    User
    |> join(:inner, [u], r in assoc(u, :roles))
    |> where([u, r], r.name == "admin" and is_nil(u.deleted_at))
    |> order_by([u], u.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Fetches the page at `url` (SSRF-guarded) for its title and excerpt:
  `{:ok, %{title, excerpt}}` or `{:error, reason}`.
  """
  def fetch_page(url) do
    case Fetcher.get(url, types: ["text/html", "application/xhtml+xml"], max_bytes: 2_000_000) do
      {:ok, %{body: body, url: final}} ->
        preview = Parser.parse(body, final)
        {:ok, %{title: preview.title, excerpt: preview.description || paragraphs(body)}}

      {:error, reason} ->
        {:error, {:fetch, reason}}
    end
  end

  # Readability, lite: the first paragraphs of the article (or main
  # content, or body), as text.
  defp paragraphs(html) do
    html = Regex.replace(~r{<(script|style|nav|header|footer|aside)\b.*?</\1>}is, html, "")

    main =
      Enum.find_value(~w(article main body), html, fn tag ->
        case Regex.run(~r{<#{tag}\b[^>]*>(.*)</#{tag}>}is, html, capture: :all_but_first) do
          [inner] -> inner
          nil -> nil
        end
      end)

    ~r{<p\b[^>]*>(.*?)</p>}is
    |> Regex.scan(main, capture: :all_but_first)
    |> Enum.map(fn [p] -> text(p) end)
    |> Enum.reject(&(String.length(&1) < 20))
    |> Enum.take(3)
    |> Enum.join("\n\n")
    |> String.slice(0, 800)
    |> present()
  end

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " "
  }

  # Tags and CDATA markers out, entities decoded, whitespace collapsed.
  defp text(html) do
    html
    |> String.replace(~r/<!\[CDATA\[|\]\]>/, "")
    |> String.replace(~r/<[^>]*>/, " ")
    |> then(
      &Regex.replace(~r/&(#\d+|[a-z]+);/i, &1, fn whole, entity -> decode(entity, whole) end)
    )
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp present(""), do: nil
  defp present(text), do: text

  defp decode("#" <> digits, whole) do
    case Integer.parse(digits) do
      {n, ""} when n in 0x20..0x10FFFF and n not in 0xD800..0xDFFF -> <<n::utf8>>
      _ -> whole
    end
  end

  defp decode(name, whole), do: Map.get(@entities, String.downcase(name), whole)

  defp create_topic(url, host, user, title, excerpt) do
    with {:ok, category} <- category(host) do
      parts = [
        excerpt && quote_text(excerpt),
        "This is a companion discussion topic for the original entry at <#{url}>"
      ]

      body = parts |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")

      attrs = %{title: String.slice(title, 0, 200), body: body, tags: host.tag}

      result = Repo.transact(fn -> insert_topic(url, host, category, user, attrs) end)

      case result do
        # Another request made it first.
        {:error, :taken} -> topic_for_url(url)
        other -> other
      end
    end
  end

  defp insert_topic(url, host, category, user, attrs) do
    with {:ok, thread} <- Discussion.create_thread(category, user, attrs) do
      embed = %TopicEmbed{embed_url: url, thread_id: thread.id, host_id: host.id}

      # `on_conflict: :nothing` leaves the id nil when the row already existed.
      case Repo.insert(embed, on_conflict: :nothing) do
        {:ok, %TopicEmbed{id: nil}} -> {:error, :taken}
        {:ok, _embed} -> {:ok, thread}
        error -> error
      end
    end
  end

  defp quote_text(excerpt),
    do: excerpt |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))

  defp category(%EmbeddableHost{category_id: id}) when is_integer(id) do
    case Discussion.get_category(id) do
      nil -> first_category()
      category -> {:ok, category}
    end
  end

  defp category(_host), do: first_category()

  defp first_category do
    case Discussion.list_categories() do
      [category | _] -> {:ok, category}
      [] -> {:error, :no_category}
    end
  end

  @doc """
  The thread with id `id` if anyone may read it (embedded comments are
  public), else nil.
  """
  def public_thread(id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Thread{} = thread <- Discussion.get_thread(id),
         true <- Bodyguard.permit?(Discussion, :view_thread, nil, thread) do
      thread
    else
      _ -> nil
    end
  end

  @doc "`thread`'s latest `limit` published replies, oldest first, with their authors."
  def replies(%Thread{id: id}, limit \\ 10) do
    first_id =
      Repo.one(
        from(p in Post,
          where: p.thread_id == ^id,
          order_by: [asc: p.inserted_at, asc: p.id],
          limit: 1,
          select: p.id
        )
      )

    query =
      from(p in Post,
        where:
          p.thread_id == ^id and p.id != ^first_id and is_nil(p.deleted_at) and
            is_nil(p.queued_at) and is_nil(p.hidden_at),
        order_by: [desc: p.inserted_at, desc: p.id],
        limit: ^limit,
        preload: :user
      )

    Enum.reverse(Repo.all(query))
  end

  @doc "How many published replies `thread` has."
  def reply_count(%Thread{id: id}) do
    Repo.one(
      from(p in Post,
        where:
          p.thread_id == ^id and is_nil(p.deleted_at) and is_nil(p.queued_at) and
            is_nil(p.hidden_at),
        select: count()
      )
    ) - 1
  end

  ## Feed

  @doc """
  Makes topics for the `embed_feed_url` feed's new entries, once an hour
  across nodes (run by `Firefly.Moderation.TopicTimers.Scheduler`).
  """
  def run_due do
    url = String.trim(SiteSettings.get("embed_feed_url"))

    if url != "" and JobRuns.claim("embed.feed", 3600) do
      case poll_feed(url) do
        {:ok, _count} -> :ok
        {:error, reason} -> Logger.warning("Embed feed #{url}: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc """
  Makes topics for the feed at `url`'s entries that are on an embeddable
  host and have none: `{:ok, count}`.
  """
  def poll_feed(url) do
    with :ok <- writable(),
         {:ok, user} <- embed_user(),
         {:ok, %{body: xml}} <- Fetcher.get(url, types: @feed_types, max_bytes: 2_000_000) do
      known = MapSet.new(Repo.all(from(e in TopicEmbed, select: e.embed_url)))

      created =
        xml
        |> entries()
        |> Enum.map(&%{&1 | link: normalize_url(&1.link)})
        |> Enum.reject(&MapSet.member?(known, &1.link))
        |> Enum.take(@max_feed_topics)
        |> Enum.count(&create_from_entry(&1, user))

      {:ok, created}
    end
  end

  defp create_from_entry(entry, user) do
    case host_for(entry.link) do
      nil ->
        false

      host ->
        match?(
          {:ok, _thread},
          create_topic(entry.link, host, user, entry.title || entry.link, entry.summary)
        )
    end
  end

  @doc "A feed's entries (RSS items or Atom entries): `[%{link, title, summary}]`."
  def entries(xml) do
    for [entry | _] <- Regex.scan(~r{<(item|entry)\b.*?</\1>}s, xml),
        link = entry_link(entry),
        link != nil do
      summary = element(entry, ~w(description summary content))

      %{
        link: link,
        title: element(entry, ["title"]),
        summary: summary && String.slice(summary, 0, 800)
      }
    end
  end

  defp entry_link(entry) do
    link =
      case Regex.run(~r{<link\b[^>]*href="([^"]+)"[^>]*/?>}s, entry, capture: :all_but_first) do
        [href] -> href
        nil -> element(entry, ["link"])
      end

    if is_binary(link) and String.starts_with?(link, ["http://", "https://"]), do: text(link)
  end

  defp element(entry, tags) do
    Enum.find_value(tags, fn tag ->
      case Regex.run(~r{<#{tag}\b[^>]*>(.*?)</#{tag}>}s, entry, capture: :all_but_first) do
        [inner] -> present(text(inner))
        nil -> nil
      end
    end)
  end
end
