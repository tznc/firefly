defmodule Firefly.SEO.Sitemap do
  @moduledoc """
  The sitemap index and its sitemaps (see `Firefly.SEO`).

  Only public content is listed: topics in categories no group restricts
  (as `Firefly.Discussion.Policy.readable_threads/2` sees them for a
  visitor), not archived, merged or awaiting approval, and whose first
  post is published. Each entry's `lastmod` is the newest published post
  in it; a category's and a tag's is the newest post anywhere under it.
  """

  import Ecto.Query

  alias Firefly.Discussion.{Category, Policy, Post, Tag, Thread}
  alias Firefly.{Repo, URLs}

  # Sitemaps hold at most 50,000 URLs; half that keeps them small to serve.
  @per_sitemap 25_000

  @doc "How many topics one sitemap holds."
  def per_sitemap, do: @per_sitemap

  @doc "The sitemaps to list in the index: `%{name, lastmod}`."
  def index do
    topics = Repo.aggregate(public_threads(), :count)
    pages = max(div(topics - 1, @per_sitemap) + 1, 1)

    for name <- ["categories", "tags"] ++ Enum.map(1..pages, &"topics-#{&1}"),
        {:ok, entries} <- [entries(name)],
        entries != [] do
      %{name: name, lastmod: entries |> Enum.map(& &1.lastmod) |> Enum.max(DateTime)}
    end
  end

  @doc "A sitemap's entries by name: `{:ok, entries}` or `:error`."
  def entries("categories"), do: {:ok, categories()}
  def entries("tags"), do: {:ok, tags()}

  def entries("topics-" <> page) do
    case Integer.parse(page) do
      {page, ""} when page > 0 -> {:ok, topics(page)}
      _other -> :error
    end
  end

  def entries(_name), do: :error

  defp topics(page) do
    public_threads()
    |> join(:inner, [thread: t], p in subquery(last_post_at()),
      as: :post,
      on: p.thread_id == t.id
    )
    |> order_by([thread: t], asc: t.id)
    |> offset(^((page - 1) * @per_sitemap))
    |> limit(@per_sitemap)
    |> select([thread: t, category: c, post: p], {t, c, p.at})
    |> Repo.all()
    |> Enum.map(fn {thread, category, last_post_at} ->
      entry(URLs.thread_url(%{thread | category_id: category.id}), last_post_at)
    end)
  end

  defp categories do
    latest =
      from(t in Thread,
        join: p in subquery(last_post_at()),
        on: p.thread_id == t.id,
        group_by: t.category_id,
        select: %{category_id: t.category_id, at: max(p.at)}
      )

    Category
    |> Policy.readable_categories(nil)
    |> join(:left, [c], l in subquery(latest), on: l.category_id == c.id)
    |> select([c, l], {c, l.at})
    |> Repo.all()
    |> Enum.map(fn {category, at} ->
      entry(URLs.category_url(category), at || category.updated_at)
    end)
  end

  defp tags do
    public_threads()
    |> join(:inner, [thread: t], tt in "forums_threads_tags",
      as: :threads_tags,
      on: tt.thread_id == t.id
    )
    |> join(:inner, [threads_tags: tt], tag in Tag, as: :tag, on: tag.id == tt.tag_id)
    |> join(:inner, [thread: t], p in subquery(last_post_at()),
      as: :post,
      on: p.thread_id == t.id
    )
    |> group_by([tag: tag], tag.name)
    |> select([tag: tag, post: p], {tag.name, max(p.at)})
    |> Repo.all()
    |> Enum.map(fn {name, at} ->
      entry("#{Firefly.Endpoint.url()}/tags/#{URI.encode(name)}", at)
    end)
  end

  # The threads a visitor may read, with their category bound.
  defp public_threads do
    Thread
    |> from(as: :thread)
    |> join(:inner, [thread: t], c in Category, as: :category, on: c.id == t.category_id)
    |> where([thread: t], is_nil(t.archived_at) and is_nil(t.merged_into_id))
    |> where(
      [thread: t],
      exists(
        from(p in Post.visible(),
          where: p.thread_id == parent_as(:thread).id and is_nil(p.hidden_at)
        )
      )
    )
    |> Policy.readable_threads(nil)
  end

  defp last_post_at do
    Post.visible()
    |> where([p], is_nil(p.hidden_at))
    |> group_by([p], p.thread_id)
    |> select([p], %{thread_id: p.thread_id, at: max(p.inserted_at)})
  end

  defp entry(loc, at), do: %{loc: loc, lastmod: at(at)}

  defp at(%DateTime{} = at), do: DateTime.truncate(at, :second)

  defp at(%NaiveDateTime{} = at),
    do: DateTime.from_naive!(NaiveDateTime.truncate(at, :second), "Etc/UTC")

  defp at(nil), do: DateTime.from_unix!(0)
end
