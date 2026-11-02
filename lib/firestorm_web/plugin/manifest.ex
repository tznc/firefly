defmodule FirestormWeb.Plugin.Manifest do
  @moduledoc """
  A plugin's manifest: `plugin.json` in an uploaded bundle, the `use
  FirestormWeb.Plugin` options of a core plugin. Validated strictly: unknown
  keys, hooks or permissions are errors, not ignored, so a typo can't
  silently drop a permission check or a hook.

      {
        "id": "hello",                      // [a-z][a-z0-9_-]{1,39}, unique
        "name": "Hello",
        "version": "1.2.0",                 // semantic version
        "firefly": "~> 1.0",                // plugin API requirement
        "description": "Says hello.",
        "author": "Jane",
        "url": "https://example.com",       // optional
        "license": "MIT",                   // optional
        "main": "index.js",                 // bundles only; default index.js
        "hooks": ["enabled"],
        "permissions": ["read"],
        "settings": [{"key": "greeting", "type": "string", "default": "Hi",
                      "label": "Greeting", "help": "What to say."}],
        "assets": ["widget.html"],
        "dependencies": {"other": "~> 1.2"},
        "optional_dependencies": {"extra": ">= 0.3.0"},
        "exports": ["greet"],               // functions dependents may call
        "priority": 100,                    // lower runs first among peers
        "source": "upload"                  // "upload" for bundles, "core" for core plugins
      }

  `source` and `registry` are there for the Firefly Cloud registry to come:
  a registry plugin will say `"source": "registry"` and carry where it came
  from (and its signature) in `registry`. Until then only uploads and core
  plugins load, and a manifest claiming another source is rejected.

  Setting types: `string` (one line, up to 500 characters), `text` (up to
  5,000), `integer` (with optional `min`/`max`), `boolean`, and `enum`
  (one of `choices`). Every setting has a `default`, which must be valid.
  """

  alias FirestormWeb.Plugin
  alias FirestormWeb.Plugin.{Host, Settings}

  @enforce_keys [:id, :name, :version, :firefly]
  defstruct [
    :id,
    :name,
    :version,
    :firefly,
    :url,
    :license,
    :registry,
    description: "",
    author: "",
    main: "index.js",
    hooks: [],
    permissions: [],
    settings: [],
    assets: [],
    dependencies: %{},
    optional_dependencies: %{},
    exports: [],
    priority: 100,
    source: "upload"
  ]

  @type t :: %__MODULE__{}

  @keys ~w(id name version firefly description author url license main hooks permissions
           settings assets dependencies optional_dependencies exports priority source registry)
  @required ~w(id name version firefly)
  @id_format ~r/^[a-z][a-z0-9_-]{1,39}$/
  @path_format ~r{^[A-Za-z0-9_-][A-Za-z0-9._/-]*$}
  @name_format ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc "Whether `id` is a valid plugin id."
  def valid_id?(id), do: is_binary(id) and id =~ @id_format

  @doc """
  Parses and validates a decoded manifest (string keys). `source` is where
  it came from (`"upload"` or `"core"`); a manifest may repeat it, but not
  contradict it. Returns `{:ok, manifest}` or `{:error, message}` naming
  every problem.
  """
  @spec parse(map, String.t()) :: {:ok, t} | {:error, String.t()}
  def parse(attrs, source) when is_map(attrs) do
    errors =
      Enum.map(Map.keys(attrs) -- @keys, &"unknown key \"#{&1}\"") ++
        Enum.map(@required -- Map.keys(attrs), &"\"#{&1}\" is required")

    errors =
      Enum.reduce(@keys, errors, fn key, errors ->
        case Map.fetch(attrs, key) do
          {:ok, value} -> errors ++ check(key, value, source)
          :error -> errors
        end
      end)

    if errors == [] do
      {:ok, build(attrs, source)}
    else
      {:error, "Invalid manifest: " <> Enum.join(errors, "; ") <> "."}
    end
  end

  def parse(_attrs, _source), do: {:error, "Invalid manifest: it must be a JSON object."}

  defp build(attrs, source) do
    fields =
      for key <- @keys, Map.has_key?(attrs, key), into: %{} do
        {String.to_existing_atom(key), attrs[key]}
      end

    struct!(
      __MODULE__,
      Map.merge(fields, %{
        source: source,
        settings: Enum.map(Map.get(attrs, "settings", []), &Settings.definition/1)
      })
    )
  end

  defp check("id", id, _source),
    do:
      if(valid_id?(id),
        do: [],
        else: ["\"id\" must be 2-40 lowercase letters, digits, - or _, starting with a letter"]
      )

  defp check(key, value, _source) when key in ~w(name author license),
    do: string(key, value, if(key == "name", do: 1, else: 0), 100)

  defp check("description", value, _source), do: string("description", value, 0, 500)

  defp check("url", value, _source) do
    case value do
      "https://" <> _ when byte_size(value) <= 500 -> []
      "http://" <> _ when byte_size(value) <= 500 -> []
      _ -> ["\"url\" must be an http(s) URL"]
    end
  end

  defp check("version", value, _source) do
    case is_binary(value) && Version.parse(value) do
      {:ok, _} -> []
      _ -> ["\"version\" must be a semantic version like 1.0.0"]
    end
  end

  defp check("firefly", value, _source) do
    case requirement(value) do
      {:ok, requirement} ->
        if Version.match?(Plugin.api_version(), requirement),
          do: [],
          else: [
            "it needs Firefly plugin API #{value}, but this is #{Plugin.api_version()}"
          ]

      :error ->
        ["\"firefly\" must be a version requirement like ~> 1.0"]
    end
  end

  defp check("main", value, _source) do
    if is_binary(value) and value =~ @path_format and String.ends_with?(value, ".js") and
         not String.contains?(value, ".."),
       do: [],
       else: ["\"main\" must be the path of a .js file in the bundle"]
  end

  defp check("hooks", value, _source),
    do: known_list("hooks", value, Plugin.manifest_hooks(), "hook")

  defp check("permissions", value, _source),
    do: known_list("permissions", value, Host.permissions(), "permission")

  defp check("exports", value, _source) do
    if is_list(value) and Enum.all?(value, &(is_binary(&1) and &1 =~ @name_format)),
      do: duplicates("exports", value),
      else: ["\"exports\" must be a list of function names"]
  end

  defp check("assets", value, _source) do
    if is_list(value) and length(value) <= 50 and
         Enum.all?(value, &(is_binary(&1) and &1 =~ @path_format and not (&1 =~ ".."))),
       do: duplicates("assets", value),
       else: ["\"assets\" must be a list of file paths in the bundle"]
  end

  defp check(key, value, _source) when key in ~w(dependencies optional_dependencies) do
    if is_map(value) do
      Enum.flat_map(value, fn {id, requirement} ->
        cond do
          not valid_id?(id) ->
            ["\"#{key}\" names an invalid plugin id \"#{id}\""]

          requirement(requirement) == :error ->
            ["\"#{key}\": \"#{id}\" needs a version requirement"]

          true ->
            []
        end
      end)
    else
      ["\"#{key}\" must be an object of plugin ids to version requirements"]
    end
  end

  defp check("priority", value, _source) do
    if is_integer(value) and value in 0..1000,
      do: [],
      else: ["\"priority\" must be a whole number from 0 to 1000"]
  end

  defp check("source", value, source) do
    cond do
      value == source -> []
      value == "registry" -> ["plugins from a registry aren't supported yet"]
      true -> ["\"source\" must be \"#{source}\""]
    end
  end

  defp check("registry", _value, _source),
    do: ["\"registry\" is reserved for plugins from a registry, which aren't supported yet"]

  defp check("settings", value, _source) do
    if is_list(value) and length(value) <= 50 do
      Enum.flat_map(value, &Settings.check_definition/1) ++
        duplicates("settings", Enum.map(value, &(is_map(&1) && &1["key"])))
    else
      ["\"settings\" must be a list of at most 50 settings"]
    end
  end

  defp string(key, value, min, max) do
    if is_binary(value) and String.length(String.trim(value)) in min..max//1,
      do: [],
      else: ["\"#{key}\" must be text of #{min} to #{max} characters"]
  end

  defp known_list(key, value, known, noun) do
    if is_list(value) and Enum.all?(value, &is_binary/1) do
      Enum.map(value -- known, &"unknown #{noun} \"#{&1}\"") ++ duplicates(key, value)
    else
      ["\"#{key}\" must be a list of strings"]
    end
  end

  defp duplicates(key, values) do
    case values -- Enum.uniq(values) do
      [] -> []
      repeated -> ["\"#{key}\" repeats #{Enum.map_join(Enum.uniq(repeated), ", ", &inspect/1)}"]
    end
  end

  @doc "Parses a version requirement: `{:ok, requirement}` or `:error`."
  def requirement(value) when is_binary(value), do: Version.parse_requirement(value)
  def requirement(_value), do: :error

  @doc "Every requirement `manifest` has, with whether it's optional: `[{id, requirement, optional?}]`."
  def requirements(%__MODULE__{} = manifest) do
    Enum.map(Enum.sort(manifest.dependencies), fn {id, req} -> {id, req, false} end) ++
      Enum.map(Enum.sort(manifest.optional_dependencies), fn {id, req} -> {id, req, true} end)
  end

  @doc "`value` (a keyword list or map, nested) with string keys, for `parse/2`."
  def stringify(value) when is_list(value) do
    if Keyword.keyword?(value) and value != [],
      do: Map.new(value, fn {key, v} -> {to_string(key), stringify(v)} end),
      else: Enum.map(value, &stringify/1)
  end

  def stringify(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, v} -> {to_string(key), stringify(v)} end)

  def stringify(value), do: value

  @doc "The manifest as stored and shown: plain JSON-encodable data."
  def to_map(%__MODULE__{} = manifest) do
    manifest
    |> Map.from_struct()
    |> Map.update!(:settings, fn settings -> Enum.map(settings, &Settings.to_map/1) end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> stringify()
  end
end
