defmodule FireflyWeb.EmbedHTML do
  @moduledoc "The embedded comments page (see `FireflyWeb.EmbedController`)."
  use FireflyWeb, :html

  alias Firefly.Rendering.Markdown

  def comments(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="firefly">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>{if @thread, do: @thread.title, else: "Comments"}</title>
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body class={["embed bg-transparent p-2", @class_name]}>
        <p :if={@error} id="embed-error" class="text-sm text-base-content/70">{@error}</p>
        <div :if={@thread} id="embed-comments" class="space-y-3">
          <p :if={@replies == []} class="text-sm text-base-content/70">No replies yet: start the discussion.</p>
          <article :for={post <- @replies} id={"embed-post-#{post.id}"} class="space-y-1 border-b border-base-300 pb-3">
            <header class="flex items-center gap-2 text-sm">
              <strong>@{post.user.username}</strong>
              <time datetime={NaiveDateTime.to_iso8601(post.inserted_at) <> "Z"} class="text-base-content/60">
                {Calendar.strftime(post.inserted_at, "%b %-d, %Y")}
              </time>
            </header>
            <div class="prose prose-sm max-w-none">
              {Phoenix.HTML.raw(Markdown.render(post.body))}
            </div>
          </article>
          <p class="flex flex-wrap gap-2">
            <a
              id="continue"
              href={url(~p"/categories/#{@thread.category_id}/threads/#{@thread}")}
              target="_blank"
              rel="noopener"
              class="btn btn-sm btn-primary"
            >
              {if @reply_count > length(@replies), do: "Continue discussion (#{@reply_count} replies)", else: "Continue discussion"}
            </a>
            <a
              id="reply"
              href={url(~p"/categories/#{@thread.category_id}/threads/#{@thread}/posts/new")}
              target="_blank"
              rel="noopener"
              class="btn btn-sm"
            >
              Reply
            </a>
          </p>
        </div>
        <script>
          (function () {
            function resize() {
              parent.postMessage({type: "firefly-embed-resize", height: document.documentElement.scrollHeight}, "*");
            }
            window.addEventListener("load", resize);
            window.addEventListener("resize", resize);
            resize();
          })();
        </script>
      </body>
    </html>
    """
  end
end
