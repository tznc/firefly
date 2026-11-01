defmodule FirestormWeb.OEmbed.Scrubber do
  @moduledoc """
  Allow-list for oEmbed HTML: https iframes (players) and images, plus basic
  text markup. Scripts, event handlers, styles and other schemes are removed.
  """
  use HtmlSanitizeEx

  allow_tag_with_uri_attributes("iframe", ["src"], ["https"])

  allow_tag_with_these_attributes("iframe", [
    "width",
    "height",
    "title",
    "frameborder",
    "allow",
    "allowfullscreen",
    "referrerpolicy",
    "loading"
  ])

  allow_tag_with_uri_attributes("img", ["src"], ["https"])
  allow_tag_with_these_attributes("img", ["width", "height", "alt", "title"])
  allow_tag_with_uri_attributes("a", ["href"], ["https"])
  allow_tag_with_these_attributes("a", ["title"])
  allow_tag_with_these_attributes("blockquote", [])
  allow_tag_with_these_attributes("p", [])
  allow_tag_with_these_attributes("br", [])
  allow_tag_with_these_attributes("em", [])
  allow_tag_with_these_attributes("strong", [])
end
