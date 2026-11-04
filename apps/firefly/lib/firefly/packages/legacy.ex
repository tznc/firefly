defmodule Firefly.Packages.Legacy do
  @moduledoc """
  The theme JSON bundle Firefly exported before packages (`name`,
  `description`, `component`, `colors`, `css`, `head_html`, `header_html`,
  `footer_html`, `components` as nested bundles and `assets` inline as
  base64), turned into a package: version 1.0.0, tagged `theme`, its id
  made from its name, the CSS and HTML as files.
  """

  alias Firefly.Packages.Archive

  @texts [
    {"css", "theme.css"},
    {"head_html", "head.html"},
    {"header_html", "header.html"},
    {"footer_html", "footer.html"}
  ]

  @doc "Whether `data` looks like an old theme bundle (JSON, not a zip)."
  def bundle?(data), do: String.starts_with?(String.trim_leading(data), "{")

  @doc "Reads an old bundle as a package: `{:ok, archive}` or `{:error, message}`."
  @spec read(binary) :: {:ok, Archive.t()} | {:error, String.t()}
  def read(json) do
    with {:ok, %{"name" => name} = bundle} when is_binary(name) <- Jason.decode(json),
         {:ok, theme, files} <- section(bundle, "") do
      manifest = %{
        "id" => id(name),
        "name" => String.slice(String.trim(name), 0, 100),
        "version" => "1.0.0",
        "firefly" => "~> 1.0",
        "description" => String.slice(bundle["description"] || "", 0, 500),
        "tags" => ["theme"],
        "theme" => theme
      }

      Archive.read(Archive.build(manifest, files))
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _invalid -> {:error, "That isn't a package (.zip) or a theme bundle (JSON with a name)."}
    end
  end

  # A bundle's theme section and files, under `dir` in the package.
  defp section(bundle, dir) do
    texts =
      for {key, file} <- @texts, text = bundle[key], is_binary(text) and text != "", into: %{} do
        {key, {dir <> file, text}}
      end

    with {:ok, assets} <- assets(bundle["assets"] || [], dir),
         {:ok, components, component_files} <- components(bundle["components"] || []) do
      theme =
        bundle
        |> Map.take(~w(name description component colors))
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.merge(Map.new(texts, fn {key, {path, _text}} -> {key, path} end))
        |> Map.put("assets", Map.new(assets, fn {name, path, _data} -> {name, path} end))
        |> then(&if(components == [], do: &1, else: Map.put(&1, "components", components)))

      files =
        Map.merge(
          Map.new(Map.values(texts)),
          Map.new(assets, fn {_name, path, data} -> {path, data} end)
        )

      {:ok, theme, Map.merge(files, component_files)}
    end
  end

  defp components(bundles) when is_list(bundles) do
    bundles
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], %{}}, fn {bundle, n}, {:ok, sections, files} ->
      case is_map(bundle) && section(Map.delete(bundle, "components"), "components/#{n}/") do
        {:ok, theme, more} ->
          {:cont, {:ok, sections ++ [Map.put(theme, "component", true)], Map.merge(files, more)}}

        _invalid ->
          {:halt, {:error, "A component in the bundle isn't valid."}}
      end
    end)
  end

  defp components(_other), do: {:error, "The bundle's components aren't a list."}

  defp assets(assets, dir) when is_list(assets) do
    Enum.reduce_while(assets, {:ok, []}, fn asset, {:ok, acc} ->
      with %{"name" => name, "filename" => filename, "data" => data} <- asset,
           true <- is_binary(name) and is_binary(filename),
           {:ok, bytes} <- Base.decode64(data) do
        {:cont, {:ok, acc ++ [{name, "#{dir}assets/#{name}/#{Path.basename(filename)}", bytes}]}}
      else
        _invalid -> {:halt, {:error, "An asset in the bundle isn't valid."}}
      end
    end)
  end

  defp assets(_other, _dir), do: {:error, "The bundle's assets aren't a list."}

  @doc "A package id from a name: lowercase letters, digits and -, starting with a letter."
  def id(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 34)
      |> String.trim("-")

    cond do
      slug =~ ~r/^[a-z][a-z0-9-]+$/ -> slug
      slug == "" -> "theme"
      true -> "theme-" <> slug
    end
  end
end
