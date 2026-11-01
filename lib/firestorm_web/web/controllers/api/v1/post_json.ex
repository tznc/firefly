defmodule FirestormWeb.Web.Api.V1.PostJSON do
  @moduledoc "JSON representation of posts."
  alias FirestormWeb.{Markdown, OEmbed}
  alias FirestormWeb.Forums.Post

  def show(%{post: %Post{} = post}), do: data(post)

  def data(%Post{} = post) do
    # A deleted or hidden post's content is only for admins, on the site.
    body = if Post.deleted?(post) or Post.hidden?(post), do: "", else: post.body

    %{
      id: post.id,
      body: body,
      body_html: Markdown.render(body),
      deleted: Post.deleted?(post),
      hidden: Post.hidden?(post),
      awaiting_approval: Post.queued?(post),
      user_id: post.user_id,
      oembeds:
        Enum.map(post.oembeds || [], fn {url, oembed} -> [url, OEmbed.to_html(oembed)] end),
      inserted_at: post.inserted_at,
      updated_at: post.updated_at,
      thread_id: post.thread_id
    }
  end
end
