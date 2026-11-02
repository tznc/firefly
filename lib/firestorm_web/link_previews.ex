defmodule FirestormWeb.LinkPreviews do
  @moduledoc """
  Link previews ("oneboxes"): a bare link on a line of its own in a post
  (see `urls/1`) shows as a card with the page's title, description, site
  name and image, from its OpenGraph or Twitter card tags. Links an oEmbed
  provider handles (see `FirestormWeb.OEmbed`) are embedded instead.

  Pages are fetched server-side by `FirestormWeb.LinkPreviews.Fetcher`
  (public addresses only, checked on every redirect; time and size
  limits; HTML only) and the result is cached in `link_previews` for the
  `link_preview_hours` site setting, failures for an hour. The image is
  copied into uploads (a public `"preview"` variant, scaled down), or
  dropped: cards never load other sites' images.

  Nothing waits for a fetch: saving a post (`resolve/1`) and showing posts
  whose previews are missing or stale (`decorate/1`) start fetches in the
  background, and the thread's open pages are told to re-render once
  they're done (`{:link_previews_ready, thread_id}` on the thread's
  topic). A row claimed for fetching (see `claim/2`) isn't fetched again
  meanwhile, by this node or another. The `link_previews` site setting
  turns all of it off. Previews unseen for 30 days are deleted by the
  scheduler (`run_due/0`).

  `config :firestorm_web, FirestormWeb.LinkPreviews, enabled: false` turns
  fetching off (in tests, which turn it on where they need it).
  """

  import Ecto.Query
  require Logger

  alias FirestormWeb.{OEmbed, Repo, SiteSettings, Uploads}
  alias FirestormWeb.Forums.Post
  alias FirestormWeb.LinkPreviews.{Fetcher, LinkPreview, Parser}

  @max_per_post 5
  @max_html 2 * 1024 * 1024
  @max_image 5 * 1024 * 1024
  @image_types ~w(image/png image/jpeg image/gif image/webp)
  # How long a fetch may hold its claim, and a failure stays cached.
  @claim_minutes 5
  @failed_minutes 60
  @unused_days 30

  @doc "The task supervisor fetches run under."
  def supervisor, do: FirestormWeb.LinkPreviews.TaskSupervisor

  @doc "Whether previews are on (the `link_previews` site setting)."
  def enabled?, do: SiteSettings.get("link_previews")

  @doc """
  The URLs in `body` that get a preview: bare http(s) links alone on
  their line (not in code, not link text), at most 5, without those an
  oEmbed provider handles.
  """
  def urls(body) when is_binary(body) do
    body
    |> MDEx.parse_document!(FirestormWeb.Markdown.options())
    |> lines()
    |> Enum.flat_map(fn
      [%MDEx.Link{url: url, nodes: [%MDEx.Text{literal: url}]}] -> [url]
      _other -> []
    end)
    |> Enum.filter(&previewable?/1)
    |> Enum.uniq()
    |> Enum.take(@max_per_post)
  end

  def urls(_body), do: []

  # Each paragraph's lines, as lists of their inline nodes, blank text out.
  defp lines(%MDEx.Paragraph{nodes: nodes}) do
    nodes
    |> Enum.chunk_by(
      &match?(%{__struct__: type} when type in [MDEx.SoftBreak, MDEx.LineBreak], &1)
    )
    |> Enum.map(fn line -> Enum.reject(line, &blank?/1) end)
  end

  defp lines(%{nodes: nodes}), do: Enum.flat_map(nodes, &lines/1)
  defp lines(_leaf), do: []

  defp blank?(%MDEx.Text{literal: text}), do: String.trim(text) == ""
  defp blank?(%{__struct__: type}), do: type in [MDEx.SoftBreak, MDEx.LineBreak]

  defp previewable?(url) do
    String.starts_with?(url, ["https://", "http://"]) and byte_size(url) <= 2000 and
      OEmbed.provider_for(url) == nil
  end

  @doc """
  The posts with `link_previews` set: the cached previews (with a title)
  of their `urls/1`, in order. Deleted posts get none. Missing or stale
  previews are fetched in the background (see the module doc).
  """
  def decorate(posts), do: if(enabled?(), do: decorate_enabled(posts), else: posts)

  defp decorate_enabled(posts) do
    wanted =
      for post <- posts, not Post.deleted?(post), into: %{}, do: {post.id, urls(post.body)}

    cached = cached(wanted |> Map.values() |> List.flatten() |> Enum.uniq())
    refresh_stale(posts, wanted, cached)

    Enum.map(posts, fn %Post{} = post ->
      %Post{post | link_previews: shown(Map.get(wanted, post.id, []), cached)}
    end)
  end

  defp shown(urls, cached), do: for(url <- urls, preview = shown(cached[url]), do: preview)

  defp shown(%LinkPreview{title: title} = preview) when is_binary(title), do: preview
  defp shown(_missing_or_failed), do: nil

  defp cached([]), do: %{}

  defp cached(urls) do
    LinkPreview
    |> where([p], p.url_hash in ^Enum.map(urls, &hash/1))
    |> preload(:image_upload)
    |> Repo.all()
    |> Map.new(&{&1.url, &1})
  end

  defp refresh_stale(posts, wanted, cached) do
    now = DateTime.utc_now()

    for post <- posts,
        urls = Map.get(wanted, post.id, []),
        stale = Enum.filter(urls, &stale?(cached[&1], now)),
        stale != [] do
      refresh(stale, post.thread_id)
    end
  end

  defp stale?(nil, _now), do: true
  defp stale?(%LinkPreview{expires_at: at}, now), do: DateTime.before?(at, now)

  @doc "Fetches the previews `post`'s body wants, in the background."
  def resolve(%Post{} = post) do
    if enabled?() do
      case urls(post.body) do
        [] -> :ok
        urls -> refresh(urls, post.thread_id)
      end
    end

    :ok
  end

  defp refresh(urls, thread_id) do
    if Application.get_env(:firestorm_web, __MODULE__, [])[:enabled] != false do
      {:ok, _pid} =
        Task.Supervisor.start_child(supervisor(), fn -> fetch_all(urls, thread_id) end)
    end

    :ok
  end

  @doc false
  def fetch_all(urls, thread_id) do
    fetched = for url <- urls, claim(url) != nil, do: fetch(url)

    if fetched != [] do
      Phoenix.PubSub.broadcast(
        FirestormWeb.PubSub,
        "forums:thread:#{thread_id}",
        {:link_previews_ready, thread_id}
      )
    end

    :ok
  end

  @doc """
  Claims `url` for fetching: its row, if it's missing or stale (it's
  then held for a few minutes), else nil (fresh, or someone else is
  fetching it).
  """
  def claim(url, now \\ DateTime.utc_now(:second)) do
    hold = DateTime.add(now, @claim_minutes, :minute)

    now_naive = NaiveDateTime.utc_now()

    row = %{
      url_hash: hash(url),
      url: url,
      status: "pending",
      expires_at: hold,
      inserted_at: now_naive,
      updated_at: now_naive
    }

    case Repo.insert_all(LinkPreview, [row],
           on_conflict:
             from(p in LinkPreview,
               where: p.expires_at < ^now,
               update: [set: [expires_at: ^hold]]
             ),
           conflict_target: :url_hash,
           returning: true
         ) do
      {1, [claimed]} -> claimed
      {0, []} -> nil
    end
  end

  defp fetch(url) do
    preview = Repo.get_by!(LinkPreview, url_hash: hash(url))

    case Fetcher.get(url, types: ["text/html", "application/xhtml+xml"], max_bytes: @max_html) do
      {:ok, page} -> save(preview, Parser.parse(page.body, page.url))
      {:error, reason} -> failed(preview, reason)
    end
  end

  defp save(preview, %{title: nil}), do: failed(preview, :no_title)

  defp save(preview, fields) do
    image = image(fields.image)
    ttl = SiteSettings.get("link_preview_hours")

    preview
    |> Ecto.Changeset.change(
      status: "ok",
      title: fields.title,
      description: fields.description,
      site_name: fields.site_name,
      image_upload_id: image && image.id,
      expires_at: DateTime.add(DateTime.utc_now(:second), ttl, :hour)
    )
    |> Repo.update!()
    |> tap(fn _ -> replaced_image(preview, image) end)
  end

  defp failed(preview, reason) do
    Logger.info("No link preview for #{preview.url}: #{inspect(reason)}")

    preview
    |> Ecto.Changeset.change(
      status: if(preview.title, do: "ok", else: "failed"),
      expires_at: DateTime.add(DateTime.utc_now(:second), @failed_minutes, :minute)
    )
    |> Repo.update!()
  end

  # The page's image, copied into uploads; nil if it can't be had.
  defp image(nil), do: nil

  defp image(url) do
    with {:ok, file} <- Fetcher.get(url, types: @image_types, max_bytes: @max_image),
         {:ok, upload} <- Uploads.create_for_site(file.body, "preview", variant: "preview") do
      upload
    else
      _failed -> nil
    end
  end

  defp replaced_image(%LinkPreview{image_upload_id: nil}, _new), do: :ok
  defp replaced_image(%LinkPreview{image_upload_id: id}, %{id: id}), do: :ok

  defp replaced_image(%LinkPreview{image_upload_id: id}, _new) do
    case Repo.get(Uploads.Upload, id) do
      nil -> :ok
      upload -> Uploads.remove(upload)
    end
  end

  @doc "Deletes previews no one has looked at in 30 days, with their images."
  def run_due(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@unused_days, :day)
    unused = Repo.all(from(p in LinkPreview, where: p.expires_at < ^cutoff))

    for preview <- unused do
      Repo.delete!(preview)
      replaced_image(preview, nil)
    end

    length(unused)
  end

  defp hash(url), do: Base.encode16(:crypto.hash(:sha256, url), case: :lower)
end
