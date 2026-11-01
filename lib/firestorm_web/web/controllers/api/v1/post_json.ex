defmodule FirestormWeb.Web.Api.V1.PostJSON do
  @moduledoc "JSON representation of posts."
  alias FirestormWeb.{Markdown, OEmbed}
  alias FirestormWeb.Forums.Post

  def show(%{post: %Post{} = post}), do: data(post)

  @doc "`refs`: see `FirestormWeb.Markdown.render/2`."
  def data(%Post{} = post, refs \\ nil) do
    # A deleted or hidden post's content (link previews included) is only
    # for admins, on the site.
    redacted? = Post.deleted?(post) or Post.hidden?(post)
    body = if redacted?, do: "", else: post.body
    oembeds = if redacted?, do: [], else: post.oembeds || []

    %{
      id: post.id,
      body: body,
      body_html: Markdown.render(body, refs),
      deleted: Post.deleted?(post),
      hidden: Post.hidden?(post),
      user_id: post.user_id,
      oembeds: Enum.map(oembeds, fn {url, oembed} -> [url, OEmbed.to_html(oembed)] end),
      inserted_at: post.inserted_at,
      updated_at: post.updated_at,
      thread_id: post.thread_id
    }
  end
end
