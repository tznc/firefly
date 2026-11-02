defmodule FirestormWeb.Plugin.Bundle do
  @moduledoc """
  An uploaded plugin: a `.zip` holding `plugin.json` (the manifest, see
  `FirestormWeb.Plugin.Manifest`) and the plugin's JavaScript, plus any
  assets the manifest lists. The files may also sit in one top-level folder,
  as zipping a folder gives.

  JavaScript files are CommonJS modules: each gets `module`, `exports` and
  `require` (relative paths, `./lib/util` or `./lib/util.js`). The `main`
  file's exports are the plugin's handlers. `code/1` joins them into the
  one script the sandbox evaluates.

  Limits: the zip at most 1 MB, at most 100 files and 5 MB
  unpacked; paths are relative, without `..`.
  """

  alias FirestormWeb.Plugin.Manifest

  @max_zip 1024 * 1024
  @max_files 100
  @max_unpacked 5 * 1024 * 1024

  @enforce_keys [:manifest, :files, :checksum, :zip]
  defstruct [:manifest, :files, :checksum, :zip]

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          files: %{String.t() => binary},
          checksum: String.t(),
          zip: binary
        }

  @doc "The largest bundle accepted, in bytes."
  def max_size, do: @max_zip

  @doc """
  Reads and validates a bundle: `{:ok, bundle}` or `{:error, message}`
  saying what's wrong.
  """
  @spec read(binary) :: {:ok, t} | {:error, String.t()}
  def read(zip) when byte_size(zip) > @max_zip,
    do: {:error, "The bundle is over #{div(@max_zip, 1024)} KB."}

  def read(zip) when is_binary(zip) do
    with {:ok, entries} <- list(zip),
         {:ok, files} <- extract(zip, entries),
         {:ok, files} <- unwrap(files),
         {:ok, json} <- fetch(files, "plugin.json", "The bundle has no plugin.json."),
         {:ok, attrs} <- decode(json),
         {:ok, manifest} <- Manifest.parse(attrs, "upload"),
         :ok <- check_files(manifest, files) do
      {:ok,
       %__MODULE__{
         manifest: manifest,
         files: files,
         checksum: Base.encode16(:crypto.hash(:sha256, zip), case: :lower),
         zip: zip
       }}
    end
  end

  # Checks the sizes the zip declares before inflating anything.
  defp list(zip) do
    case :zip.list_dir(zip) do
      {:ok, [_comment | entries]} ->
        files =
          for {:zip_file, name, info, _comment, _offset, _size} <- entries,
              not String.ends_with?(to_string(name), "/"),
              do: {to_string(name), elem(info, 1)}

        cond do
          length(files) > @max_files ->
            {:error, "The bundle has more than #{@max_files} files."}

          Enum.sum_by(files, &elem(&1, 1)) > @max_unpacked ->
            {:error, "The bundle unpacks to more than #{div(@max_unpacked, 1024 * 1024)} MB."}

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
         {:ok, extracted} <- :zip.extract(zip, [:memory]) do
      files = for {name, data} <- extracted, into: %{}, do: {to_string(name), data}

      if Enum.sum_by(Map.values(files), &byte_size/1) > @max_unpacked,
        do: {:error, "The bundle unpacks to more than #{div(@max_unpacked, 1024 * 1024)} MB."},
        else: {:ok, Map.drop(files, Enum.filter(Map.keys(files), &junk?/1))}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, _} -> {:error, "The file isn't a valid .zip."}
    end
  end

  defp check_paths(names) do
    case Enum.find(names, &(not safe_path?(&1))) do
      nil -> :ok
      bad -> {:error, "The bundle has a file with an unsafe path: #{bad}."}
    end
  end

  defp safe_path?(path) do
    String.valid?(path) and not String.starts_with?(path, "/") and
      not Enum.member?(Path.split(path), "..") and not String.contains?(path, "\\")
  end

  # Files zip tools add that aren't the plugin's.
  defp junk?(path),
    do: String.starts_with?(path, "__MACOSX/") or Path.basename(path) == ".DS_Store"

  # Zipping a folder puts everything in it: look inside a lone top folder.
  defp unwrap(files) do
    if Map.has_key?(files, "plugin.json") do
      {:ok, files}
    else
      case Enum.uniq(Enum.map(Map.keys(files), &hd(Path.split(&1)))) do
        [folder] ->
          prefix = folder <> "/"

          {:ok,
           Map.new(files, fn {path, data} -> {String.replace_prefix(path, prefix, ""), data} end)}

        _ ->
          {:ok, files}
      end
    end
  end

  defp fetch(files, path, message) do
    case Map.fetch(files, path) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, message}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, attrs} -> {:ok, attrs}
      {:error, _} -> {:error, "plugin.json isn't valid JSON."}
    end
  end

  defp check_files(manifest, files) do
    missing = Enum.reject([manifest.main | manifest.assets], &Map.has_key?(files, &1))
    invalid = for {path, data} <- files, js?(path), not String.valid?(data), do: path

    cond do
      missing != [] -> {:error, "The bundle is missing #{Enum.join(missing, ", ")}."}
      invalid != [] -> {:error, "#{Enum.join(invalid, ", ")} must be UTF-8 text."}
      true -> :ok
    end
  end

  defp js?(path), do: String.ends_with?(path, ".js")

  @doc """
  The plugin's code as one script: a small CommonJS loader, each `.js` file
  as a module, then the main module's exports as the global `exports` the
  sandbox calls handlers on.
  """
  @spec code(t) :: String.t()
  def code(%__MODULE__{manifest: manifest, files: files}) do
    modules =
      for {path, source} <- Enum.sort(files), js?(path) do
        # Each file is a function body, so its top-level names stay its own.
        "__modules[#{Jason.encode!(path)}] = function (module, exports, require) {\n" <>
          source <> "\n};\n"
      end

    """
    (function () {
    var __modules = {};
    #{modules}
    var __cache = {};
    function __resolve(from, name) {
      if (name.slice(0, 2) !== "./" && name.slice(0, 3) !== "../") throw new Error("cannot require " + name + ": only relative paths");
      var parts = from.split("/").slice(0, -1);
      name.split("/").forEach(function (part) {
        if (part === "..") parts.pop(); else if (part !== "." && part !== "") parts.push(part);
      });
      var path = parts.join("/");
      if (__modules[path]) return path;
      if (__modules[path + ".js"]) return path + ".js";
      throw new Error("cannot find module " + name);
    }
    function __require(path) {
      if (__cache[path]) return __cache[path].exports;
      var module = { exports: {} };
      __cache[path] = module;
      __modules[path](module, module.exports, function (name) { return __require(__resolve(path, name)); });
      return module.exports;
    }
    globalThis.exports = __require(#{Jason.encode!(manifest.main)});
    })();
    """
  end
end
