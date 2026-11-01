defmodule FirestormWeb.Web.Api.V1.PostJSON do
  @moduledoc "JSON representation of posts."
  alias FirestormWeb.{Markdown, OEmbed}
  alias FirestormWeb.Forums.Post

  def show(%{post: %Post{} = post}), do: data(post)

  @doc "`refs`: see `FirestormWeb.Markdown.render/2`."
  def data(%Post{} = post, refs \\ nil) do
    # A deleted post's content is only for admins, on the site.
    body = if Post.deleted?(post), do: "", else: post.body

    %{
      id: post.id,
      body: body,
      body_html: Markdown.render(body, refs),
      deleted: Post.deleted?(post),
      user_id: post.user_id,
      oembeds:
        Enum.map(post.oembeds || [], fn {url, oembed} -> [url, OEmbed.to_html(oembed)] end),
      inserted_at: post.inserted_at,
      updated_at: post.updated_at,
      thread_id: post.thread_id
    }
  end
end
