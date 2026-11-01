defmodule FirestormWeb.Web.Api.V1.PostJSON do
  @moduledoc "JSON representation of posts."
  alias FirestormWeb.{Markdown, OEmbed}
  alias FirestormWeb.Forums.Post

  def show(%{post: %Post{} = post}), do: data(post)

  @doc "`refs`: see `FirestormWeb.Markdown.render/2`."
  def data(%Post{} = post, refs \\ nil) do
    # The API and channels serve anyone: a post's content (link previews
    # included) only once it's public, not while deleted, hidden or queued.
    redacted? = not Post.readable_by?(post, nil)
    body = if redacted?, do: "", else: post.body
    oembeds = if redacted?, do: [], else: post.oembeds || []

    %{
      id: post.id,
      body: body,
      body_html: Markdown.render(body, refs),
      deleted: Post.deleted?(post),
      hidden: Post.hidden?(post),
      queued: Post.queued?(post),
      awaiting_approval: Post.queued?(post),
      user_id: post.user_id,
      oembeds: Enum.map(oembeds, fn {url, oembed} -> [url, OEmbed.to_html(oembed)] end),
      inserted_at: post.inserted_at,
      updated_at: post.updated_at,
      thread_id: post.thread_id
    }
  end
end
