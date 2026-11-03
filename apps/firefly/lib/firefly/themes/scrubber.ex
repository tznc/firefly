defmodule Firefly.Themes.Scrubber do
  @moduledoc """
  The allow-list a theme's head, header and footer HTML is cleaned with
  unless the theme may run scripts (see `Firefly.Themes`): markup, links,
  images and `<meta>`/`<link>` tags, with no scripts, event handlers,
  inline styles or `javascript:` URLs.
  """
  use HtmlSanitizeEx

  allow_tag_with_these_attributes("meta", ["name", "content", "property"])
  allow_tag_with_uri_attributes("link", ["href"], ["https", "http"])
  allow_tag_with_these_attributes("link", ["rel", "type", "sizes", "media", "crossorigin"])
  allow_tag_with_uri_attributes("a", ["href"], ["https", "http", "mailto"])

  allow_tag_with_these_attributes("a", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir",
    "rel",
    "target"
  ])

  allow_tag_with_uri_attributes("img", ["src"], ["https", "http"])

  allow_tag_with_these_attributes("img", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir",
    "alt",
    "width",
    "height",
    "loading"
  ])

  allow_tag_with_these_attributes("div", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("span", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("p", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("nav", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("header", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("footer", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("section", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("aside", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("ul", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("ol", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("li", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("h1", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("h2", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("h3", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("h4", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("h5", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("h6", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("strong", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("em", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("b", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("i", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("small", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("br", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("hr", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("blockquote", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("code", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("pre", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("figure", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])

  allow_tag_with_these_attributes("figcaption", [
    "class",
    "id",
    "title",
    "role",
    "aria-label",
    "aria-hidden",
    "lang",
    "dir"
  ])
end
