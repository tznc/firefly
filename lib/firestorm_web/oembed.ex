defmodule FirestormWeb.OEmbed do
  @moduledoc """
  oEmbed lookups, backed by an LRU cache that is populated asynchronously.
  """

  @cache_name :oembed_cache

  def for(url) do
    case get(url) do
      nil ->
        Task.start(fn -> fetch_and_cache(url) end)

        {:error, "Fetching to populate cache, check again later."}

      result ->
        {:ok, result}
    end
  end

  def get(url) do
    LruCache.get(@cache_name, url)
  end

  defp fetch_and_cache(url) do
    with {:ok, result} <- OEmbed.for(url) do
      LruCache.put(@cache_name, url, result)
      {:ok, result}
    end
  end
end
