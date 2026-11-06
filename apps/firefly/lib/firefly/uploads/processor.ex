defmodule Firefly.Uploads.Processor do
  @moduledoc """
  Checks what an uploaded file really is and prepares it for storing.

  The type comes from the file's content, never from its name or the
  browser's claim, and a name or claim that disagrees with the content is
  refused: PNG, JPEG, GIF and WebP images, SVG images (made PNGs, see
  `rasterize_svg/1`), PDFs, plain text (valid UTF-8 named `.txt`) and, for
  themes, WOFF and WOFF2 fonts. Anything else (HTML, scripts,
  executables) is refused.

  Images are decoded with libvips (through `Image`/`Vix`) and written
  again: turned upright from their EXIF orientation, with all metadata
  (EXIF, GPS position, camera details, comments) removed, scaled down to
  fit `max_dimension` pixels, plus a thumbnail when larger than
  `thumbnail_size/0`. Animated GIFs keep their frames, so they're stored
  as uploaded (GIF has no EXIF to strip) with no downscaling or thumbnail.
  Avatars are cropped square to `avatar_size/0`, with a square
  `avatar_thumbnail_size/0` thumbnail for small avatars in lists; profile
  and user card backgrounds are scaled to fit `background_size/0`; custom emoji are scaled
  to fit `emoji_size/0` (animated GIF emoji are kept as uploaded), link
  preview images to fit `thumbnail_size/0`.
  """

  @thumbnail_size 640
  @avatar_size 256
  @avatar_thumbnail_size 96
  @background_size 1600
  @emoji_size 128
  # Pixels a decoded image may have: bigger is a decompression bomb, not a photo.
  @max_pixels 50_000_000

  @doc "The longest side of a thumbnail, in pixels."
  def thumbnail_size, do: @thumbnail_size

  @doc "An avatar's side, in pixels."
  def avatar_size, do: @avatar_size

  @doc "A small avatar's side, in pixels."
  def avatar_thumbnail_size, do: @avatar_thumbnail_size

  @doc "A profile or card background's longest side, in pixels."
  def background_size, do: @background_size

  @doc "A custom emoji's longest side, in pixels."
  def emoji_size, do: @emoji_size

  @doc "The file extension stored files of `content_type` get."
  def extension("image/png"), do: ".png"
  def extension("image/jpeg"), do: ".jpg"
  def extension("image/gif"), do: ".gif"
  def extension("image/webp"), do: ".webp"
  def extension("image/svg+xml"), do: ".svg"
  def extension("application/pdf"), do: ".pdf"
  def extension("text/plain"), do: ".txt"
  def extension("font/woff2"), do: ".woff2"
  def extension("font/woff"), do: ".woff"

  @doc """
  The content type of `data` named `filename` (and, if given, claimed to
  be `claimed_type` by the browser or client), if it's one that's accepted:
  `{:ok, type}` or `{:error, message}`. The type comes from the content; a
  name or claimed type that says otherwise is refused, so a PDF can't pass
  as `photo.png` nor a PNG as `application/pdf`. A name without an
  extension, and a generic claim (`application/octet-stream`), say nothing.
  SVG images are `image/svg+xml` here; `rasterize_svg/1` makes them PNGs.
  """
  def detect(data, filename, claimed_type \\ nil) do
    with {:ok, type} <- sniff(data, filename),
         :ok <- check_extension(type, filename),
         :ok <- check_claim(type, claimed_type),
         do: {:ok, type}
  end

  defp sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>, _filename),
    do: {:ok, "image/png"}

  defp sniff(<<0xFF, 0xD8, 0xFF, _::binary>>, _filename), do: {:ok, "image/jpeg"}
  defp sniff(<<"GIF8", v, "a", _::binary>>, _filename) when v in [?7, ?9], do: {:ok, "image/gif"}
  defp sniff(<<"RIFF", _::32, "WEBP", _::binary>>, _filename), do: {:ok, "image/webp"}
  defp sniff(<<"%PDF-", _::binary>>, _filename), do: {:ok, "application/pdf"}
  # Web fonts, which only themes may upload (see Firefly.Uploads).
  defp sniff(<<"wOF2", _::binary>>, _filename), do: {:ok, "font/woff2"}
  defp sniff(<<"wOFF", _::binary>>, _filename), do: {:ok, "font/woff"}

  defp sniff(data, filename) do
    cond do
      svg?(data) -> {:ok, "image/svg+xml"}
      text?(data, filename) -> {:ok, "text/plain"}
      true -> {:error, "That file type isn't allowed."}
    end
  end

  # Plain text only when named so: text is what HTML and scripts are too.
  defp text?(data, filename),
    do:
      extension_of(filename) == ".txt" and String.valid?(data) and
        not String.contains?(data, <<0>>)

  # An SVG document: an <svg> root, after at most an XML declaration,
  # comments and a DOCTYPE without an internal subset. Entity declarations
  # (billion laughs, external entities) are refused outright.
  @svg_root ~r/\A(?:\x{FEFF})?\s*(?:<\?xml[^>]*\?>\s*)?(?:<!--.*?-->\s*)*(?:<!DOCTYPE\s+svg[^>\[]*>\s*)?(?:<!--.*?-->\s*)*<svg[\s>]/su

  defp svg?(data),
    do: String.valid?(data) and Regex.match?(@svg_root, data) and not (data =~ ~r/<!ENTITY/i)

  # The extensions a file of each type may be named with.
  @extensions %{
    "image/png" => ~w(.png),
    "image/jpeg" => ~w(.jpg .jpeg .jpe .jfif),
    "image/gif" => ~w(.gif),
    "image/webp" => ~w(.webp),
    "image/svg+xml" => ~w(.svg),
    "application/pdf" => ~w(.pdf),
    "text/plain" => ~w(.txt),
    "font/woff2" => ~w(.woff2),
    "font/woff" => ~w(.woff)
  }

  # Other names clients use for the same types.
  @aliases %{
    "image/jpg" => "image/jpeg",
    "image/pjpeg" => "image/jpeg",
    "image/x-png" => "image/png",
    "application/x-pdf" => "application/pdf",
    "application/font-woff" => "font/woff",
    "application/x-font-woff" => "font/woff",
    "application/font-woff2" => "font/woff2"
  }

  # Claims that say nothing about the type.
  @generic ["", "application/octet-stream", "binary/octet-stream", "application/unknown"]

  defp extension_of(filename), do: filename |> to_string() |> Path.extname() |> String.downcase()

  defp check_extension(type, filename) do
    case extension_of(filename) do
      "" -> :ok
      extension -> if extension in @extensions[type], do: :ok, else: mismatch()
    end
  end

  defp check_claim(_type, nil), do: :ok

  defp check_claim(type, claimed) do
    claimed = claimed |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    claimed = Map.get(@aliases, claimed, claimed)
    if claimed in @generic or claimed == type, do: :ok, else: mismatch()
  end

  defp mismatch, do: {:error, "That file's content doesn't match its type."}

  @doc """
  Renders an SVG image to a PNG, at its own size (`{:ok, png}` or
  `{:error, message}`). Rasterizing rather than sanitizing: no script,
  `foreignObject`, event handler, external reference or styling trick
  survives as pixels, there's no SVG allow-list to keep ahead of browser
  quirks, and every image then goes through the same libvips path. librsvg
  renders it from memory, with no base location, so it loads nothing
  external. Vector scaling is what's lost.
  """
  def rasterize_svg(data) do
    with {:ok, image} <- open(data),
         :ok <- check_pixels(image) do
      case Image.write(image, :memory, suffix: ".png") do
        {:ok, png} -> {:ok, png}
        {:error, _reason} -> {:error, "That image couldn't be processed."}
      end
    end
  end

  @doc """
  Prepares `data` of `content_type` for storing. `:max_dimension` caps an
  image's longest side; `variant: "avatar"` crops it square (with a small
  square thumbnail), `"background"` fits it to `background_size/0`, `"emoji"`
  scales it to emoji size. Returns
  `{:ok, %{data: data, width: w, height: h, thumbnail: data | nil}}`
  (no dimensions for other files) or `{:error, message}`.
  """
  def process(data, "image/" <> _ = content_type, opts) do
    with {:ok, image} <- open(data),
         :ok <- check_pixels(image) do
      case opts[:variant] do
        "avatar" -> avatar(image, content_type)
        "emoji" -> image(data, image, content_type, @emoji_size)
        "background" -> image(data, image, content_type, @background_size)
        "preview" -> image(data, image, content_type, @thumbnail_size)
        "site" -> image(data, image, content_type, @background_size)
        "theme" -> image(data, image, content_type, @background_size)
        nil -> image(data, image, content_type, opts[:max_dimension])
      end
    end
  end

  def process(data, _content_type, _opts),
    do: {:ok, %{data: data, width: nil, height: nil, thumbnail: nil}}

  defp open(data) do
    case Image.from_binary(data) do
      {:ok, image} -> {:ok, image}
      {:error, _reason} -> {:error, "That image couldn't be read."}
    end
  end

  defp check_pixels(image) do
    if Image.width(image) * Image.height(image) <= @max_pixels,
      do: :ok,
      else: {:error, "That image is too large to process."}
  end

  defp image(data, image, "image/gif", _max_dimension),
    do:
      {:ok, %{data: data, width: Image.width(image), height: Image.height(image), thumbnail: nil}}

  defp image(_data, image, content_type, max_dimension) do
    with {:ok, {image, _flags}} <- Image.autorotate(image),
         {:ok, image} <- fit(image, max_dimension),
         {:ok, data} <- encode(image, content_type),
         {:ok, thumbnail} <- thumbnail(image, content_type) do
      {:ok,
       %{data: data, width: Image.width(image), height: Image.height(image), thumbnail: thumbnail}}
    else
      {:error, _reason} -> {:error, "That image couldn't be processed."}
    end
  end

  defp avatar(image, content_type) do
    with {:ok, {image, _flags}} <- Image.autorotate(image),
         {:ok, image} <- Image.thumbnail(image, @avatar_size, crop: :attention),
         {:ok, small} <- Image.thumbnail(image, @avatar_thumbnail_size, crop: :attention),
         {:ok, data} <- encode(image, content_type),
         {:ok, thumbnail} <- encode(small, content_type) do
      {:ok,
       %{data: data, width: Image.width(image), height: Image.height(image), thumbnail: thumbnail}}
    else
      {:error, _reason} -> {:error, "That image couldn't be processed."}
    end
  end

  defp fit(image, max) do
    if max(Image.width(image), Image.height(image)) > max,
      do: Image.thumbnail(image, max, resize: :down),
      else: {:ok, image}
  end

  defp thumbnail(image, content_type) do
    if max(Image.width(image), Image.height(image)) > @thumbnail_size do
      with {:ok, small} <- Image.thumbnail(image, @thumbnail_size, resize: :down),
           do: encode(small, content_type)
    else
      {:ok, nil}
    end
  end

  defp encode(image, content_type),
    do: Image.write(image, :memory, suffix: extension(content_type), strip_metadata: true)
end
