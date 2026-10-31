defmodule FirestormWeb.Web.OembedHelpers do
  @moduledoc """
  Renders oEmbed results as HTML.
  """

  def render_oembed(%OEmbed.Photo{url: url}) do
    PhoenixHTMLHelpers.Tag.img_tag(url)
  end

  def render_oembed(%OEmbed.Video{html: html}) do
    Phoenix.HTML.raw(html)
  end

  def render_oembed(%OEmbed.Rich{html: html}) do
    Phoenix.HTML.raw(html)
  end

  def render_oembed(_), do: nil
end
