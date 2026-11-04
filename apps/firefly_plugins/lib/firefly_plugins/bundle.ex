defmodule FireflyPlugins.Bundle do
  @moduledoc """
  A package with plugin code (see `Firefly.Packages`), as the sandbox
  sees it: the domain reads and validates the `.zip`
  (`Firefly.Packages.Archive`); this turns its JavaScript into the one
  script the sandbox evaluates.

  JavaScript files are CommonJS modules: each gets `module`, `exports` and
  `require` (relative paths, `./lib/util` or `./lib/util.js`). The `main`
  file's exports are the plugin's handlers.
  """

  alias Firefly.Packages.Archive

  @doc """
  Reads a package that has plugin code: `{:ok, archive}` or `{:error,
  message}`.
  """
  @spec read(binary) :: {:ok, Archive.t()} | {:error, String.t()}
  def read(zip) do
    case Archive.read(zip) do
      {:ok, %Archive{manifest: %{main: nil}}} -> {:error, "The package has no plugin code."}
      other -> other
    end
  end

  @doc """
  The plugin's code as one script: a small CommonJS loader, each `.js` file
  as a module, then the main module's exports as the global `exports` the
  sandbox calls handlers on.
  """
  @spec code(Archive.t()) :: String.t()
  def code(%Archive{manifest: manifest, files: files}) do
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

  defp js?(path), do: String.ends_with?(path, ".js")
end
