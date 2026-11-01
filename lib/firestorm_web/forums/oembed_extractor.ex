defmodule FirestormWeb.Forums.OembedExtractor do
  @moduledoc """
  Finds the URLs in a post body and resolves their (cached) oEmbed data.
  """

  @url_regex ~r(https?://[^ $\n]*)

  def get_embeds(body) do
    body
    |> get_urls_from_string()
    |> Task.async_stream(fn url -> {url, FirestormWeb.OEmbed.for(url)} end)
    |> Enum.filter(&successful_oembed?/1)
    |> Enum.map(fn {:ok, {url, {:ok, a}}} -> {url, a} end)
  end

  defp successful_oembed?({:ok, {_url, {:ok, _data}}}), do: true
  defp successful_oembed?(_), do: false

  @doc """
  Gathers anything in the string that looks like a link into a list of links.
  """
  def get_urls_from_string(string) do
    @url_regex
    |> Regex.scan(string)
    |> Enum.map(&hd/1)
  end
end
