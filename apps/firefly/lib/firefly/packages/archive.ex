defmodule Firefly.Packages.Archive do
  @moduledoc """
  A package as uploaded or fetched: a `.zip` holding its manifest
  (`firefly.json`, or `plugin.json` as plugin bundles always had, see
  `Firefly.Plugin.Manifest`) and the files it names: the plugin's
  JavaScript, its assets, and its theme's CSS, HTML and asset files. The
  files may also sit in one top-level folder, as zipping a folder (or
  downloading a GitHub repository) gives.

  Reading one validates all of it, the theme section included (see
  `Firefly.Packages`), without running anything: a package that is only a
  theme needs no plugin sandbox.

  Limits: the zip at most 5 MB, at most 200 files and 20 MB unpacked
  (counted as it inflates, whatever sizes the zip declares); paths are
  relative, without `..`.
  """

  alias Firefly.Plugin.Manifest
  alias Firefly.Themes.Palette

  @max_zip 5 * 1024 * 1024
  @max_files 200
  @max_unpacked 20 * 1024 * 1024
  @manifest_files ["firefly.json", "plugin.json"]

  @enforce_keys [:manifest, :files, :checksum, :zip]
  defstruct [:manifest, :files, :checksum, :zip]

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          files: %{String.t() => binary},
          checksum: String.t(),
          zip: binary
        }

  @theme_keys ~w(name description component colors css head_html header_html footer_html assets
                 components)
  @text_keys ~w(css head_html header_html footer_html)
  @asset_name ~r/^[a-z0-9][a-z0-9_-]{0,39}$/

  @doc "The largest package accepted, in bytes."
  def max_size, do: @max_zip

  @doc """
  Reads and validates a package: `{:ok, archive}` or `{:error, message}`
  saying what's wrong.
  """
  @spec read(binary) :: {:ok, t} | {:error, String.t()}
  def read(zip) when byte_size(zip) > @max_zip,
    do: {:error, "The package is over #{div(@max_zip, 1024 * 1024)} MB."}

  def read(zip) when is_binary(zip) do
    with {:ok, entries} <- list(zip),
         {:ok, files} <- extract(zip, entries),
         files = unwrap(files),
         nil <- legacy(files),
         {:ok, json} <- manifest_file(files),
         {:ok, attrs} <- decode(json),
         {:ok, manifest} <- Manifest.parse(attrs, "upload"),
         :ok <- check_files(manifest, files),
         :ok <- check_theme(manifest.theme, files) do
      {:ok,
       %__MODULE__{
         manifest: manifest,
         files: files,
         checksum: Base.encode16(:crypto.hash(:sha256, zip), case: :lower),
         zip: zip
       }}
    end
  end

  @doc "Zips `manifest` (a map, written as `firefly.json`) with `files` (path => contents)."
  @spec build(map, %{String.t() => binary}) :: binary
  def build(manifest, files) do
    entries =
      for {path, data} <- Map.put(files, "firefly.json", Jason.encode!(manifest, pretty: true)),
          do: {String.to_charlist(path), data}

    {:ok, {_name, zip}} = :zip.create(~c"package.zip", Enum.sort(entries), [:memory])
    zip
  end

  # Checks the sizes the zip declares before inflating anything (they can
  # lie: inflating counts again, see inflate_all/2).
  defp list(zip) do
    case :zip.list_dir(zip) do
      {:ok, [_comment | entries]} ->
        # Name, declared size, and where its compressed data is.
        files =
          for {:zip_file, name, info, _comment, offset, compressed} <- entries,
              not String.ends_with?(to_string(name), "/"),
              do: {to_string(name), elem(info, 1), offset, compressed}

        cond do
          length(files) > @max_files ->
            {:error, "The package has more than #{@max_files} files."}

          Enum.sum_by(files, &elem(&1, 1)) > @max_unpacked ->
            {:error, "The package unpacks to more than #{div(@max_unpacked, 1024 * 1024)} MB."}

          true ->
            {:ok, files}
        end

      _ ->
        {:error, "The file isn't a valid .zip."}
    end
  end

  defp extract(zip, entries) do
    names = MapSet.new(entries, &elem(&1, 0))

    with :ok <- check_paths(names),
         {:ok, files} <- inflate_all(zip, entries) do
      {:ok, Map.drop(files, Enum.filter(Map.keys(files), &junk?/1))}
    end
  end

  # Inflates each file itself, counting what comes out against the limit:
  # the sizes a zip declares can lie, and :zip.extract/2 inflates whole
  # files before anything can be checked (a 5 MB zip can hold gigabytes).
  defp inflate_all(zip, entries) do
    entries
    |> Enum.reduce_while({%{}, @max_unpacked}, fn {name, _size, offset, compressed}, {files, left} ->
      case entry_data(zip, offset, compressed) do
        {:ok, method, data} ->
          case inflate(method, data, left) do
            {:ok, inflated} ->
              {:cont, {Map.put(files, name, inflated), left - byte_size(inflated)}}

            :too_big ->
              {:halt, {:error, "The package unpacks to more than #{div(@max_unpacked, 1024 * 1024)} MB."}}

            :invalid ->
              {:halt, {:error, "The file isn't a valid .zip."}}
          end

        :invalid ->
          {:halt, {:error, "The file isn't a valid .zip."}}
      end
    end)
    |> case do
      {:error, message} -> {:error, message}
      {files, _left} -> {:ok, files}
    end
  end

  # A file's compression method and compressed data, after its local
  # header (30 bytes, then its name and extra field).
  defp entry_data(zip, offset, compressed) do
    case zip do
      <<_::binary-size(^offset), 0x04034B50::little-32, _version_flags::binary-4,
        method::little-16, _times_crc_sizes::binary-16, name_length::little-16,
        extra_length::little-16, rest::binary>> ->
        case rest do
          <<_::binary-size(^name_length + ^extra_length), data::binary-size(^compressed), _::binary>> ->
            {:ok, method, data}

          _truncated ->
            :invalid
        end

      _no_header ->
        :invalid
    end
  end

  # Stored.
  defp inflate(0, data, left), do: if(byte_size(data) > left, do: :too_big, else: {:ok, data})

  # Deflated: inflated a chunk at a time, stopping past `left` bytes.
  defp inflate(8, data, left) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_chunks(z, :zlib.safeInflate(z, data), [], left)
    catch
      :error, _data_error -> :invalid
    after
      :zlib.close(z)
    end
  end

  defp inflate(_method, _data, _left), do: :invalid

  defp inflate_chunks(z, {status, chunk}, chunks, left) do
    left = left - IO.iodata_length(chunk)

    cond do
      left < 0 -> :too_big
      status == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks]))}
      # Out of input before the end of the stream: truncated.
      IO.iodata_length(chunk) == 0 -> :invalid
      true -> inflate_chunks(z, :zlib.safeInflate(z, []), [chunk | chunks], left)
    end
  end

  defp check_paths(names) do
    case Enum.find(names, &(not safe_path?(&1))) do
      nil -> :ok
      bad -> {:error, "The package has a file with an unsafe path: #{bad}."}
    end
  end

  defp safe_path?(path) do
    String.valid?(path) and not String.starts_with?(path, "/") and
      not Enum.member?(Path.split(path), "..") and not String.contains?(path, "\\")
  end

  # Files zip tools add that aren't the package's.
  defp junk?(path),
    do: String.starts_with?(path, "__MACOSX/") or Path.basename(path) == ".DS_Store"

  # Zipping a folder puts everything in it: look inside a lone top folder.
  defp unwrap(files) do
    with false <- Enum.any?(@manifest_files, &Map.has_key?(files, &1)),
         [folder] <- Enum.uniq(Enum.map(Map.keys(files), &hd(Path.split(&1)))) do
      prefix = folder <> "/"
      Map.new(files, fn {path, data} -> {String.replace_prefix(path, prefix, ""), data} end)
    else
      _manifest_at_top_or_several_folders -> files
    end
  end

  defp manifest_file(files) do
    case Enum.find(@manifest_files, &Map.has_key?(files, &1)) do
      nil -> {:error, "The package has no firefly.json (or plugin.json)."}
      name -> {:ok, files[name]}
    end
  end

  # A repository with only an old theme bundle in it.
  defp legacy(files) do
    if Map.has_key?(files, "firefly-theme.json") and
         not Enum.any?(@manifest_files, &Map.has_key?(files, &1)),
       do: Firefly.Packages.Legacy.read(files["firefly-theme.json"])
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, attrs} -> {:ok, attrs}
      {:error, _} -> {:error, "The manifest isn't valid JSON."}
    end
  end

  defp check_files(manifest, files) do
    missing = Enum.reject(List.wrap(manifest.main) ++ manifest.assets, &Map.has_key?(files, &1))
    invalid = for {path, data} <- files, js?(path), not String.valid?(data), do: path

    cond do
      missing != [] -> {:error, "The package is missing #{Enum.join(missing, ", ")}."}
      invalid != [] -> {:error, "#{Enum.join(invalid, ", ")} must be UTF-8 text."}
      true -> :ok
    end
  end

  defp js?(path), do: String.ends_with?(path, ".js")

  ## The theme section

  defp check_theme(nil, _files), do: :ok

  defp check_theme(theme, files) do
    components = Map.get(theme, "components", [])

    nesting =
      if theme["component"] == true and components != [],
        do: ["a component can't include components"],
        else: []

    errors =
      nesting ++
        theme_errors(theme, files, "theme") ++
        if is_list(components) do
          components
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {component, n} -> component_errors(component, files, n) end)
        else
          ["\"components\" must be a list"]
        end

    if errors == [],
      do: :ok,
      else: {:error, "Invalid theme: " <> Enum.join(errors, "; ") <> "."}
  end

  defp component_errors(component, files, n) when is_map(component) do
    nested =
      if Map.has_key?(component, "components"),
        do: ["components can't include components"],
        else: []

    nested ++ theme_errors(component, files, "component #{n}")
  end

  defp component_errors(_component, _files, n), do: ["component #{n} must be an object"]

  defp theme_errors(theme, files, what) do
    unknown =
      for key <- Map.keys(theme) -- @theme_keys, do: "#{what} has an unknown key \"#{key}\""

    unknown ++
      text_errors(theme, files, what) ++
      color_errors(Map.get(theme, "colors", %{}), what) ++
      asset_errors(Map.get(theme, "assets", %{}), files, what) ++
      field_errors(theme, what)
  end

  defp field_errors(theme, what) do
    for {key, check} <- [
          {"name", &(is_binary(&1) and String.trim(&1) != "")},
          {"description", &is_binary/1},
          {"component", &is_boolean/1}
        ],
        Map.has_key?(theme, key),
        not check.(theme[key]),
        do: "#{what}'s \"#{key}\" is invalid"
  end

  # CSS and HTML are files in the package, named by path.
  defp text_errors(theme, files, what) do
    for key <- @text_keys,
        Map.has_key?(theme, key),
        error = text_error(theme[key], files),
        error != nil,
        do: "#{what}'s \"#{key}\" #{error}"
  end

  defp text_error(path, files) when is_binary(path) do
    case Map.fetch(files, path) do
      {:ok, data} -> if String.valid?(data), do: nil, else: "must be UTF-8 text"
      :error -> "names #{path}, which isn't in the package"
    end
  end

  defp text_error(_path, _files), do: "must be the path of a file in the package"

  defp color_errors(colors, what) when is_map(colors) do
    for {scheme, tokens} <- colors,
        error <- scheme_errors(scheme, tokens),
        do: "#{what}'s colors: #{error}"
  end

  defp color_errors(_colors, what), do: ["#{what}'s \"colors\" must be an object"]

  defp scheme_errors(scheme, tokens) when is_map(tokens) do
    if scheme in Palette.schemes() do
      for {token, value} <- tokens,
          not (token in Palette.tokens() and is_binary(value) and value =~ ~r/^#[0-9a-fA-F]{6}$/),
          do: "#{scheme} #{token} must be a known token with a color like #3b82f6"
    else
      ["unknown scheme \"#{scheme}\" (#{Enum.join(Palette.schemes(), " or ")})"]
    end
  end

  defp scheme_errors(scheme, _tokens), do: ["#{scheme} must be an object of tokens"]

  defp asset_errors(assets, files, what) when is_map(assets) do
    for {name, path} <- assets,
        error = asset_error(name, path, files),
        error != nil,
        do: "#{what}: #{error}"
  end

  defp asset_errors(_assets, _files, what),
    do: ["#{what}'s \"assets\" must be an object of names to paths"]

  defp asset_error(name, path, files) do
    cond do
      not (is_binary(name) and name =~ @asset_name) ->
        "an asset name must be lowercase letters, digits, - and _"

      not (is_binary(path) and Map.has_key?(files, path)) ->
        "asset #{name} isn't in the package"

      true ->
        nil
    end
  end
end
