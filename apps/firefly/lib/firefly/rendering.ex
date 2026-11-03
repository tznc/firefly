defmodule Firefly.Rendering do
  @moduledoc """
  The Rendering context: turning what members write into safe HTML.

  Its public modules:

    * `Firefly.Rendering.Markdown` - Markdown (and BBCode, see
      `Firefly.Rendering.BBCode`) to sanitized HTML
    * `Firefly.Rendering.Emoji` - standard and custom emoji
    * `Firefly.Rendering.OEmbed` and `OembedExtractor` - embedded media
    * `Firefly.Rendering.LinkPreviews` - previews of linked pages
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [
      Markdown,
      OEmbed,
      OembedExtractor,
      Emoji,
      Emoji.CustomEmoji,
      LinkPreviews,
      LinkPreviews.Fetcher
    ]
end
