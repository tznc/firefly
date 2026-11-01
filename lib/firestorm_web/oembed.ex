defmodule FirestormWeb.OEmbed do
  @moduledoc """
  oEmbed lookups for links in posts, backed by an LRU cache that is populated
  asynchronously.

  Only the built-in providers (YouTube, Vimeo, Instagram, Pinterest) are used.
  The library's "discoverable" fallback is deliberately skipped: it fetches
  whatever URL a user posts (server-side request forgery) and embeds whatever
  HTML that page advertises (stored XSS).
  """

  alias FirestormWeb.OEmbed.Scrubber

  @cache_name :oembed_cache
  @providers [
    OEmbed.YoutubeProvider,
    OEmbed.VimeoProvider,
    OEmbed.InstagramProvider,
    OEmbed.PinterestProvider
  ]

  def for(url) do
    case {get(url), provider_for(url)} do
      {nil, nil} ->
        {:error, "No oEmbed provider for this URL"}

      {nil, provider} ->
        Task.start(fn -> fetch_and_cache(provider, url) end)
        {:error, "Fetching to populate cache, check again later."}

      {result, _provider} ->
        {:ok, result}
    end
  end

  def get(url) do
    LruCache.get(@cache_name, url)
  end

  @doc "The built-in provider that handles `url`, if any."
  def provider_for(url) when is_binary(url) do
    Enum.find(@providers, & &1.provides?(url))
  end

  defp fetch_and_cache(provider, url) do
    with {:ok, result} <- provider.get(url) do
      LruCache.put(@cache_name, url, result)
      {:ok, result}
    end
  end

  @doc """
  The HTML for an oEmbed result. Provider HTML is sanitized (only https
  iframes and basic markup survive); photos become an escaped <img> tag.
  """
  def to_html(%OEmbed.Photo{url: url}) do
    src = url |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    Scrubber.sanitize(~s(<img src="#{src}">))
  end

  def to_html(%OEmbed.Video{html: html}) when is_binary(html), do: Scrubber.sanitize(html)
  def to_html(%OEmbed.Rich{html: html}) when is_binary(html), do: Scrubber.sanitize(html)
  def to_html(_), do: ""
end
