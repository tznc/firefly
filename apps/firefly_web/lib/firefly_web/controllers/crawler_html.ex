defmodule FireflyWeb.CrawlerHTML do
  @moduledoc "The crawler view of a topic (see `FireflyWeb.CrawlerController`)."
  use FireflyWeb, :html

  alias Firefly.Moderation.WatchedWords
  alias Firefly.Rendering.Markdown

  # Sobelow: Markdown.render/1 returns sanitized HTML.
  # sobelow_skip ["XSS.Raw"]
  def thread(assigns) do
    ~H"""
    <main class="mx-auto max-w-3xl space-y-4 p-4">
      <nav aria-label="Breadcrumb">
        <ol class="flex flex-wrap gap-2 text-sm">
          <li><a href={~p"/"} class="link">Home</a></li>
          <li><a href={~p"/categories"} class="link">Categories</a></li>
          <li><a href={~p"/categories/#{@category}"} class="link">{@category.title}</a></li>
        </ol>
      </nav>

      <header>
        <h1 class="text-2xl font-bold">{WatchedWords.censor(@thread.title)}</h1>
        <p :if={@pages > 1} class="text-sm text-base-content/70">Page {@page} of {@pages}</p>
      </header>

      <article :for={post <- @posts} id={"post-#{post.id}"} class="space-y-2 border-b border-base-300 pb-4">
        <header class="flex flex-wrap items-center gap-2 text-sm">
          <a href={~p"/users/#{post.user}"} class="link font-semibold">@{post.user.username}</a>
          <time datetime={NaiveDateTime.to_iso8601(post.inserted_at) <> "Z"} class="text-base-content/60">
            {Calendar.strftime(post.inserted_at, "%b %-d, %Y")}
          </time>
        </header>
        <div class="prose max-w-none">{Phoenix.HTML.raw(Markdown.render(post.body))}</div>
      </article>

      <nav :if={@pages > 1} aria-label="Pagination" class="flex gap-4">
        <a :if={@page > 1} rel="prev" href={page_url(@path, @page - 1)} class="link">Previous page</a>
        <a :if={@page < @pages} rel="next" href={page_url(@path, @page + 1)} class="link">Next page</a>
      </nav>
    </main>
    """
  end

  defp page_url(path, 1), do: path
  defp page_url(path, page), do: "#{path}?page=#{page}"
end
