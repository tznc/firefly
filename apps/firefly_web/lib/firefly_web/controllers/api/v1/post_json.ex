defmodule FireflyWeb.Api.V1.PostJSON do
  @moduledoc "JSON representation of posts."
  alias Firefly.Discussion.Post
  alias Firefly.Plugins.Fields
  alias Firefly.Rendering.{Markdown, OEmbed}
  alias FireflyWeb.Api.V1.UserJSON

  def show(%{post: %Post{} = post}), do: data(post)

  @doc """
  `refs`: see `Firefly.Rendering.Markdown.render/2`. `viewer` (nil: anyone)
  decides whether a deleted, hidden or queued post's content is shown
  (see `Post.readable_by?/2`); channels serve anyone.
  """
  def data(%Post{} = post, refs \\ nil, viewer \\ nil) do
    redacted? = not Post.readable_by?(post, viewer)
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
      wiki: post.wiki,
      edited_at: post.edited_at,
      user_id: post.user_id,
      oembeds: Enum.map(oembeds, fn {url, oembed} -> [url, OEmbed.to_html(oembed)] end),
      inserted_at: post.inserted_at,
      updated_at: post.updated_at,
      thread_id: post.thread_id,
      # Plugins' public custom fields, by plugin id (see Firefly.Plugins.Fields).
      plugin_fields:
        if(redacted?, do: %{}, else: Map.get(Fields.public("post", [post.id]), post.id, %{}))
    }
  end

  @doc "`data/3` with the viewer's state of the post (`extra`: likes, liked, bookmarked...)."
  def full(%Post{} = post, refs, viewer, extra) do
    post
    |> data(refs, viewer)
    |> Map.put(:user, user(post.user))
    |> Map.merge(extra)
  end

  defp user(%Firefly.Accounts.User{} = user), do: UserJSON.data(user)
  defp user(_not_loaded), do: nil
end
