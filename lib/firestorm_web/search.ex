defmodule FirestormWeb.Search do
  @moduledoc """
  Full-text search over thread titles and post bodies, with Postgres FTS:
  `search_vector` columns (GIN-indexed, kept up to date by Postgres; see the
  `AddSearchVectors` migration), `websearch_to_tsquery`
  for the query (so `"exact phrase"`, `or` and `-word` work) and
  `ts_headline` snippets.

  A query can carry filters inline, which the search page also offers as
  controls (the controls win when both are given):

    * `category:slug` - in the category or its subcategories
    * `tag:name` - threads with the tag
    * `@username` - posts by the user
    * `in:title` - match thread titles only (results are first posts)
    * `order:latest` - newest first instead of most relevant

  Threads the searcher muted (directly, or through their category or a tag;
  see `FirestormWeb.Forums.Subscriptions`) are left out unless the
  `"muted"` control is `"include"`, or the search is filtered to a category
  or tag the searcher muted (asking for it explicitly beats the mute).

  A post matches when its body matches; a thread's first post also matches
  on the title (weighted higher when ranking). Deleted posts, posts hidden
  after flags and archived threads are left out, and
  only threads the searcher may read are searched (see
  `FirestormWeb.Forums.Policy.readable_threads/2`).
  """

  import Ecto.Query

  alias FirestormWeb.Repo
  alias FirestormWeb.Forums.{Category, Policy, Post, Subscriptions, Tag, User}

  defstruct terms: "",
            category: nil,
            tag: nil,
            user: nil,
            in_title: false,
            order: "relevance",
            include_muted: false

  @type t :: %__MODULE__{}

  @orders ~w(relevance latest)
  @page_size 20

  # ts_headline marks matches with these; they're stripped from the post
  # first, so after HTML-escaping they can only be ours.
  @start_sel "\u0001"
  @stop_sel "\u0002"
  @headline_options "StartSel=#{@start_sel}, StopSel=#{@stop_sel}, MaxFragments=2, MaxWords=30, MinWords=12, FragmentDelimiter=\" … \""

  def orders, do: @orders

  defmacrop tsquery(terms) do
    quote do: fragment("websearch_to_tsquery('english', ?)", unquote(terms))
  end

  defmacrop first_post_id(thread) do
    quote do
      fragment(
        "(SELECT fp.id FROM forums_posts fp WHERE fp.thread_id = ? ORDER BY fp.inserted_at, fp.id LIMIT 1)",
        unquote(thread).id
      )
    end
  end

  @doc """
  Parses a query string with inline filters (see the module doc). `controls`
  are the search page's fields (`"category"`, `"tag"`, `"user"`, `"in"`,
  `"order"`, `"muted"`); non-blank ones override the inline filters.
  """
  @spec parse(String.t() | nil, map) :: t
  def parse(query, controls \\ %{}) do
    {filters, words} =
      (query || "")
      |> String.split()
      |> Enum.split_with(&Regex.match?(~r/^(?:(?:category|tag|order):.|in:title$|@.)/i, &1))

    filters
    |> Enum.reduce(%__MODULE__{terms: Enum.join(words, " ")}, &put_filter/2)
    |> override(controls)
  end

  defp put_filter("@" <> user, search), do: %{search | user: user}

  defp put_filter(filter, search) do
    case String.split(filter, ":", parts: 2) do
      [key, value] -> put_filter(String.downcase(key), String.downcase(value), search)
    end
  end

  defp put_filter("category", slug, search), do: %{search | category: slug}
  defp put_filter("tag", name, search), do: %{search | tag: name}
  defp put_filter("in", "title", search), do: %{search | in_title: true}
  defp put_filter("order", order, search) when order in @orders, do: %{search | order: order}
  defp put_filter(_key, _value, search), do: search

  defp override(search, controls) do
    Enum.reduce(controls, search, fn
      {key, value}, search when key in ~w(category tag user) and is_binary(value) ->
        case value |> String.trim() |> String.trim_leading("@") do
          "" -> search
          value -> Map.put(search, String.to_existing_atom(key), value)
        end

      {"in", "title"}, search ->
        %{search | in_title: true}

      {"order", order}, search when order in @orders ->
        %{search | order: order}

      {"muted", "include"}, search ->
        %{search | include_muted: true}

      _other, search ->
        search
    end)
  end

  @doc """
  Whether there's anything to search for (terms or a filter). `in:title`
  alone isn't: it only narrows terms, and listing every thread's first post
  is what the thread lists are for.
  """
  def present?(%__MODULE__{} = search) do
    search.terms != "" or not is_nil(search.category || search.tag || search.user)
  end

  @doc """
  The page of matching posts for `user` (or nil). Each entry is a map with
  the `:post` (its `user` loaded), its `:thread` (its `category` loaded) and
  a `:headline`: an HTML snippet, safe to render, with matches in `<mark>`.
  """
  @spec run(t, term, term) :: Scrivener.Page.t()
  def run(%__MODULE__{} = search, user, page \\ 1) do
    if present?(search) do
      Post
      |> Post.visible()
      |> join(:inner, [p], t in assoc(p, :thread), as: :thread)
      |> join(:inner, [p], u in assoc(p, :user), as: :user)
      |> join(:inner, [thread: t], c in assoc(t, :category), as: :category)
      |> where([p, thread: t], is_nil(t.archived_at) and is_nil(p.hidden_at))
      |> Policy.readable_threads(user)
      |> without_muted(user, search)
      |> match(search)
      |> by_category(search.category)
      |> by_tag(search.tag)
      |> by_user(search.user)
      |> order(search)
      |> select_headline(search.terms)
      |> Repo.paginate(page: page, page_size: @page_size)
      |> Map.update!(:entries, &Enum.map(&1, fn row -> result(row) end))
    else
      no_results()
    end
  end

  @doc "An empty page of results."
  @spec no_results() :: Scrivener.Page.t()
  def no_results do
    %Scrivener.Page{
      entries: [],
      page_number: 1,
      page_size: @page_size,
      total_entries: 0,
      total_pages: 1
    }
  end

  defp result({post, thread, user, category, headline}) do
    %{
      post: %{post | user: user},
      thread: %{thread | category: category},
      headline: to_html(headline)
    }
  end

  # The snippet: Postgres' ts_headline around the matches (the markers are
  # stripped from the body first, so they can only be ts_headline's), or the
  # start of the post when there are no terms.
  defp select_headline(query, "") do
    select(query, [p, thread: t, user: u, category: c], {
      p,
      t,
      u,
      c,
      fragment("left(translate(?, ?, ''), 200)", p.body, ^(@start_sel <> @stop_sel))
    })
  end

  defp select_headline(query, terms) do
    select(query, [p, thread: t, user: u, category: c], {
      p,
      t,
      u,
      c,
      fragment(
        "ts_headline('english', translate(?, ?, ''), ?, ?)",
        p.body,
        ^(@start_sel <> @stop_sel),
        tsquery(^terms),
        ^@headline_options
      )
    })
  end

  defp match(query, %{terms: "", in_title: true}),
    do: where(query, [p, thread: t], p.id == first_post_id(t))

  defp match(query, %{terms: ""}), do: query

  defp match(query, %{terms: terms, in_title: true}) do
    where(
      query,
      [p, thread: t],
      fragment("? @@ ?", t.search_vector, tsquery(^terms)) and p.id == first_post_id(t)
    )
  end

  defp match(query, %{terms: terms}),
    do: where(query, [p], fragment("? @@ ?", p.search_vector, tsquery(^terms)))

  defp without_muted(query, %User{} = user, %{include_muted: false} = search) do
    if filters_muted_scope?(user, search),
      do: query,
      else: where(query, [thread: t], t.id not in subquery(Subscriptions.muted_thread_ids(user)))
  end

  defp without_muted(query, _user, _search), do: query

  # Whether the search is filtered to a category (or its parent) or a tag
  # the user muted.
  defp filters_muted_scope?(user, %{category: category, tag: tag}) do
    category = category && Repo.get_by(Category, slug: String.downcase(category))
    tag = tag && Repo.get_by(Tag, name: String.downcase(tag))

    muted_category? =
      category != nil and
        (Subscriptions.category_level(user, category) ||
           (category.parent_id &&
              Subscriptions.category_level(user, %Category{id: category.parent_id}))) == "muted"

    muted_category? or (tag != nil and Subscriptions.tag_level(user, tag) == "muted")
  end

  defp by_category(query, nil), do: query

  defp by_category(query, slug) do
    ids = from(c in Category, where: c.slug == ^String.downcase(slug), select: c.id)
    children = from(c in Category, where: c.parent_id in subquery(ids), select: c.id)

    where(
      query,
      [thread: t],
      t.category_id in subquery(ids) or t.category_id in subquery(children)
    )
  end

  defp by_tag(query, nil), do: query

  defp by_tag(query, name) do
    tagged =
      from(tt in "forums_threads_tags",
        join: tag in Tag,
        on: tag.id == tt.tag_id,
        where: tt.thread_id == parent_as(:thread).id and tag.name == ^String.downcase(name),
        select: 1
      )

    where(query, exists(tagged))
  end

  defp by_user(query, nil), do: query

  defp by_user(query, username) do
    where(query, [user: u], fragment("lower(?)", u.username) == ^String.downcase(username))
  end

  # Without terms there's no relevance: newest first.
  defp order(query, %{order: "relevance", terms: terms}) when terms != "" do
    order_by(query, [p, thread: t],
      desc: fragment("ts_rank(?, ?)", p.search_vector, tsquery(^terms)),
      desc: p.inserted_at,
      desc: p.id
    )
  end

  defp order(query, _search), do: order_by(query, [p], desc: p.inserted_at, desc: p.id)

  # Escaped, then the match markers become <mark> tags.
  defp to_html(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(@start_sel, "<mark>")
    |> String.replace(@stop_sel, "</mark>")
  end
end
