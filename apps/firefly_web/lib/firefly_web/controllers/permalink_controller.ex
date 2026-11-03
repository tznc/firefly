defmodule FireflyWeb.PermalinkController do
  @moduledoc """
  Redirects an imported site's old URLs (`/t/welcome/12`,
  `/viewtopic.php?t=12`...) to what they became (see
  `Firefly.Import.find_permalink/2`). It's the router's last route: a path
  that's no permalink is a 404, as before.
  """
  use FireflyWeb, :controller

  alias Firefly.Import
  alias Firefly.Import.Permalink

  def show(conn, _params) do
    case Import.find_permalink(conn.request_path, conn.query_string) do
      nil ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: FireflyWeb.Router

      permalink ->
        conn
        |> put_status(:moved_permanently)
        |> redirect(target(permalink))
    end
  end

  defp target(%Permalink{external_url: url}) when is_binary(url), do: [external: url]

  defp target(%Permalink{post: %{thread: thread} = post}),
    do: [to: ~p"/categories/#{thread.category_id}/threads/#{thread}" <> "#post-#{post.id}"]

  defp target(%Permalink{thread: %{} = thread}),
    do: [to: ~p"/categories/#{thread.category_id}/threads/#{thread}"]

  defp target(%Permalink{category: %{} = category}), do: [to: ~p"/categories/#{category}"]
  defp target(%Permalink{user: %{} = user}), do: [to: ~p"/users/#{user}"]
  defp target(%Permalink{tag: %{} = tag}), do: [to: ~p"/tags/#{tag.name}"]
end
