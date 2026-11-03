defmodule FireflyWeb.EmbedController do
  @moduledoc """
  Blog comments (see `Firefly.Embedding`):

    * `GET /embed.js`: the script a site includes. It reads
      `window.FireflyEmbed` (`fireflyUrl`, `embedUrl` (default: the page's
      URL), `topicId`, `elementId` (default `firefly-comments`)), adds an
      iframe of the comments there and sizes it to its content, from the
      height the frame posts (`firefly-embed-resize` messages from
      Firefly's origin only).
    * `GET /embed/comments?embed_url=` (or `?topic_id=`): the comments
      page in the frame. Its `Content-Security-Policy` lets only the
      embeddable hosts frame it (every other page allows only Firefly
      itself) and it sends no `X-Frame-Options`. The page's topic is
      made on its first view.
  """
  use FireflyWeb, :controller

  alias Firefly.Embedding

  @script """
  (function () {
    var config = window.FireflyEmbed || {};
    var base = String(config.fireflyUrl || "").replace(/\\/+$/, "");
    var target = document.getElementById(config.elementId || "firefly-comments");
    if (!base || !target) { return; }
    var query = config.topicId
      ? "topic_id=" + encodeURIComponent(config.topicId)
      : "embed_url=" + encodeURIComponent(config.embedUrl || window.location.href.split("#")[0]);
    var frame = document.createElement("iframe");
    frame.src = base + "/embed/comments?" + query;
    frame.id = "firefly-embed-frame";
    frame.title = "Comments";
    frame.setAttribute("scrolling", "no");
    frame.style.width = "100%";
    frame.style.border = "0";
    frame.style.height = "300px";
    target.appendChild(frame);
    var origin = new URL(base, window.location.href).origin;
    window.addEventListener("message", function (event) {
      var data = event.data;
      if (event.origin !== origin || event.source !== frame.contentWindow) { return; }
      if (!data || data.type !== "firefly-embed-resize" || typeof data.height !== "number") { return; }
      frame.style.height = Math.ceil(data.height) + "px";
    });
  })();
  """

  def script(conn, _params) do
    conn
    |> put_resp_content_type("application/javascript")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, @script)
  end

  def comments(conn, params) do
    conn = put_frame_headers(conn)

    case thread(params) do
      {:ok, thread} ->
        render_comments(conn, 200,
          thread: thread,
          replies: Embedding.replies(thread),
          reply_count: Embedding.reply_count(thread),
          class_name: class_name(params),
          error: nil
        )

      {:error, status, message} ->
        render_comments(conn, status,
          thread: nil,
          replies: [],
          reply_count: 0,
          class_name: nil,
          error: message
        )
    end
  end

  defp thread(%{"topic_id" => id}) do
    case Embedding.public_thread(id) do
      nil -> {:error, 404, "This discussion isn't available."}
      thread -> {:ok, thread}
    end
  end

  defp thread(%{"embed_url" => url}) when is_binary(url) do
    case Embedding.topic_for_url(url) do
      {:ok, thread} ->
        if Embedding.public_thread(thread.id),
          do: {:ok, thread},
          else: {:error, 404, "This discussion isn't available."}

      {:error, :not_allowed} ->
        {:error, 403, "This site isn't allowed to embed discussions."}

      {:error, _reason} ->
        {:error, 503, "The discussion couldn't be loaded. Try again later."}
    end
  end

  defp thread(_params), do: {:error, 400, "No page to discuss."}

  defp class_name(%{"embed_url" => url}) do
    case Embedding.host_for(url) do
      %{class_name: class} when is_binary(class) -> class
      _ -> nil
    end
  end

  defp class_name(_params), do: nil

  # Framed by the embeddable hosts only: the CSP's frame-ancestors (what
  # X-Frame-Options would deny, it allows per host, so that isn't sent).
  defp put_frame_headers(conn) do
    ancestors = Enum.join(["'self'" | Embedding.frame_ancestors()], " ")

    conn
    |> put_secure_browser_headers(%{
      "content-security-policy" => "base-uri 'self'; frame-ancestors #{ancestors};"
    })
    |> delete_resp_header("x-frame-options")
  end

  defp render_comments(conn, status, assigns) do
    conn
    |> put_status(status)
    |> put_root_layout(false)
    |> put_layout(false)
    |> put_view(html: FireflyWeb.EmbedHTML)
    |> render(:comments, assigns)
  end
end
