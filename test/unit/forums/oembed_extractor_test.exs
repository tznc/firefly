defmodule FirestormWeb.Forums.OembedExtractorTest do
  use ExUnit.Case

  alias FirestormWeb.Forums.OembedExtractor

  test "returns a list of oembed data for a given block of text, by extracting links" do
    url = "https://www.youtube.com/watch?v=H686MDn4Lo8"

    example_text = """
    This is a cool video, check it out: #{url}
    """

    empire_city_elixir_conf_vid =
      %OEmbed.Video{
        author_name: "Empire City Elixir Conference",
        author_url: "https://www.youtube.com/channel/UCIYiFWyuEytDzyju6uXW40Q",
        cache_age: nil,
        height: 270,
        html:
          "<iframe width=\"480\" height=\"270\" src=\"https://www.youtube.com/embed/H686MDn4Lo8?feature=oembed\" frameborder=\"0\" allowfullscreen></iframe>",
        provider_name: "YouTube",
        provider_url: "https://www.youtube.com/",
        thumbnail_height: 360,
        thumbnail_url: "https://i.ytimg.com/vi/H686MDn4Lo8/hqdefault.jpg",
        thumbnail_width: 480,
        title: "Real World Elixir Deployment // Pete Gamache",
        type: "video",
        version: "1.0",
        width: 480
      }

    LruCache.put(:oembed_cache, url, empire_city_elixir_conf_vid)

    assert [{url, empire_city_elixir_conf_vid}] == OembedExtractor.get_embeds(example_text)
  end

  test "ignores links without a built-in provider, without fetching them" do
    url = "http://169.254.169.254/latest/meta-data/"
    assert FirestormWeb.OEmbed.provider_for(url) == nil
    assert {:error, _} = FirestormWeb.OEmbed.for(url)
    assert [] == OembedExtractor.get_embeds("internal: #{url} and https://evil.example.com/page")
  end

  test "looks up at most five embeds per post" do
    urls = for n <- 1..8, do: "https://www.youtube.com/watch?v=video#{n}"
    for url <- urls, do: LruCache.put(:oembed_cache, url, %OEmbed.Video{html: "<p>#{url}</p>"})

    assert length(OembedExtractor.get_embeds(Enum.join(urls, " "))) == 5
  end

  test "sanitizes provider HTML" do
    html =
      FirestormWeb.OEmbed.to_html(%OEmbed.Rich{
        html:
          ~S|<iframe src="https://www.youtube.com/embed/x" onload="alert(1)"></iframe><script>alert(1)</script><iframe src="javascript:alert(1)"></iframe>|
      })

    assert html =~ ~s(<iframe src="https://www.youtube.com/embed/x">)
    refute html =~ "onload"
    refute html =~ "<script"
    refute html =~ "javascript:"
  end
end
