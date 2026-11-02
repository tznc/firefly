defmodule FirestormWeb.Uploads.Processor do
  @moduledoc """
  Checks what an uploaded file really is and prepares it for storing.

  The type comes from the file's content, never from its name or the
  browser's claim: PNG, JPEG, GIF and WebP images, PDFs, and plain text
  (valid UTF-8 named `.txt`). Anything else (HTML, SVG, scripts,
  executables) is refused.

  Images are decoded with libvips (through `Image`/`Vix`) and written
  again: turned upright from their EXIF orientation, with all metadata
  (EXIF, GPS position, camera details, comments) removed, scaled down to
  fit `max_dimension` pixels, plus a thumbnail when larger than
  `thumbnail_size/0`. Animated GIFs keep their frames, so they're stored
  as uploaded (GIF has no EXIF to strip) with no downscaling or thumbnail.
  Avatars are cropped square to `avatar_size/0`; custom emoji are scaled
  to fit `emoji_size/0` (animated GIF emoji are kept as uploaded), link
  preview images to fit `thumbnail_size/0`.
  """

  @thumbnail_size 640
  @avatar_size 256
  @emoji_size 128
  # Pixels a decoded image may have: bigger is a decompression bomb, not a photo.
  @max_pixels 50_000_000

  @doc "The longest side of a thumbnail, in pixels."
  def thumbnail_size, do: @thumbnail_size

  @doc "An avatar's side, in pixels."
  def avatar_size, do: @avatar_size

  @doc "A custom emoji's longest side, in pixels."
  def emoji_size, do: @emoji_size

  @doc "The file extension stored files of `content_type` get."
  def extension("image/png"), do: ".png"
  def extension("image/jpeg"), do: ".jpg"
  def extension("image/gif"), do: ".gif"
  def extension("image/webp"), do: ".webp"
  def extension("application/pdf"), do: ".pdf"
  def extension("text/plain"), do: ".txt"

  @doc """
  The content type of `data` named `filename`, if it's one that's
  accepted: `{:ok, type}` or `{:error, message}`.
  """
  def detect(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>, _filename),
    do: {:ok, "image/png"}

  def detect(<<0xFF, 0xD8, 0xFF, _::binary>>, _filename), do: {:ok, "image/jpeg"}
  def detect(<<"GIF8", v, "a", _::binary>>, _filename) when v in [?7, ?9], do: {:ok, "image/gif"}
  def detect(<<"RIFF", _::32, "WEBP", _::binary>>, _filename), do: {:ok, "image/webp"}
  def detect(<<"%PDF-", _::binary>>, _filename), do: {:ok, "application/pdf"}

  def detect(data, filename) do
    if String.downcase(Path.extname(filename)) == ".txt" and String.valid?(data) and
         not String.contains?(data, <<0>>),
       do: {:ok, "text/plain"},
       else: {:error, "That file type isn't allowed."}
  end

  @doc """
  Prepares `data` of `content_type` for storing. `:max_dimension` caps an
  image's longest side; `variant: "avatar"` crops it square, `"emoji"`
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
        "preview" -> image(data, image, content_type, @thumbnail_size)
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
         {:ok, data} <- encode(image, content_type) do
      {:ok, %{data: data, width: Image.width(image), height: Image.height(image), thumbnail: nil}}
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
