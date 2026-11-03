defmodule Firefly.Rendering do
  @moduledoc """
  The Rendering context: turning what members write into safe HTML.

  Its public modules:

    * `Firefly.Rendering.Markdown` - Markdown (and BBCode) to sanitized HTML
    * `Firefly.Rendering.BBCode` - BBCode to Markdown (also for importers)
    * `Firefly.Rendering.Emoji` - standard and custom emoji
    * `Firefly.Rendering.OEmbed` and `OembedExtractor` - embedded media
    * `Firefly.Rendering.LinkPreviews` - previews of linked pages
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [
      Markdown,
      BBCode,
      OEmbed,
      OembedExtractor,
      Emoji,
      Emoji.CustomEmoji,
      LinkPreviews,
      LinkPreviews.Fetcher,
      LinkPreviews.Parser
    ]
end
