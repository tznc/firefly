defmodule FirestormWeb.Web.Api.V1.PostJSON do
  @moduledoc "JSON representation of posts."
  alias FirestormWeb.{Markdown, OEmbed}
  alias FirestormWeb.Forums.Post

  def show(%{post: %Post{} = post}), do: data(post)

  def data(%Post{} = post) do
    %{
      id: post.id,
      body: post.body,
      body_html: Markdown.render(post.body),
      user_id: post.user_id,
      oembeds:
        Enum.map(post.oembeds || [], fn {url, oembed} -> [url, OEmbed.to_html(oembed)] end),
      inserted_at: post.inserted_at,
      updated_at: post.updated_at,
      thread_id: post.thread_id
    }
  end
end
