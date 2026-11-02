defmodule FirestormWeb.UploadHelpers do
  @moduledoc "Files for upload tests."

  @doc "Writes a `width`x`height` image to `dir/name` (its type from the extension)."
  def image_file(dir, name, width \\ 40, height \\ 30) do
    path = Path.join(dir, name)
    width |> Image.new!(height, color: :red) |> Image.write!(path)
    path
  end

  @doc "Writes `contents` to `dir/name`."
  def file(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end
end
