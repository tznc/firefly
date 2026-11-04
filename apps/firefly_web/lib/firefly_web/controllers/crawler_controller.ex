defmodule FireflyWeb.CrawlerController do
  @moduledoc """
  Topics as plain server-rendered pages, for crawlers (see
  `FireflyWeb.Plugs.CrawlerView`).

  The LiveView's first render is server-rendered too, so crawlers see the
  content either way; what this adds is a page that needs no JavaScript
  at all and splits long topics into `?page=` pages (#{50} posts each)
  linked with `rel="prev"`/`rel="next"`, so a thousand-post topic isn't
  one enormous document. It serves what a visitor may read, nothing more:
  a topic in a restricted category is a 404 here as everywhere.
  """
  use FireflyWeb, :controller

  alias Firefly.Discussion
  alias Firefly.Discussion.{Post, Thread}
  alias Firefly.Moderation.WatchedWords

  @per_page 50

  @doc "How many posts a crawler page shows."
  def per_page, do: @per_page

  def thread(conn, %{"category_id" => category_id, "id" => id} = params) do
    thread = Discussion.get_thread!(id)
    category = Discussion.get_visible_category!(thread.category_id, nil)
    thread = Discussion.get_visible_thread!(category, id, nil)

    cond do
      Thread.merged?(thread) ->
        redirect(conn, to: merged_path(thread))

      to_string(thread.category_id) != category_id ->
        redirect(conn, to: ~p"/categories/#{thread.category_id}/threads/#{thread}")

      true ->
        render_thread(conn, category, thread, page(params))
    end
  end

  defp render_thread(conn, category, thread, page) do
    posts = thread |> Firefly.Repo.preload(posts: :user) |> Map.fetch!(:posts)
    # Only published posts: deleted, hidden and queued ones are nobody's business.
    posts = Enum.filter(posts, &Post.readable_by?(&1, nil))
    pages = max(div(length(posts) - 1, @per_page) + 1, 1)
    page = min(page, pages)
    shown = posts |> Enum.drop((page - 1) * @per_page) |> Enum.take(@per_page)
    path = ~p"/categories/#{category}/threads/#{thread}"

    conn
    |> assign(:page_title, "#{WatchedWords.censor(thread.title)} - #{category.title}")
    |> FireflyWeb.SEO.assign(
      thread
      |> FireflyWeb.SEO.thread(category, posts)
      |> Map.put(:canonical, if(page == 1, do: path, else: "#{path}?page=#{page}"))
    )
    |> put_root_layout(html: {FireflyWeb.Layouts, :root})
    |> render(:thread,
      category: category,
      thread: thread,
      posts: shown,
      page: page,
      pages: pages,
      path: path
    )
  end

  defp page(params) do
    case Integer.parse(to_string(params["page"] || "1")) do
      {page, ""} when page > 0 -> page
      _other -> 1
    end
  end

  defp merged_path(thread) do
    case Discussion.get_thread_after_merges(thread.merged_into_id) do
      nil -> ~p"/"
      target -> ~p"/categories/#{target.category_id}/threads/#{target}"
    end
  end
end
