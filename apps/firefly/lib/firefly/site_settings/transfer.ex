defmodule Firefly.SiteSettings.Transfer do
  @moduledoc """
  Site settings as a file, to copy them between sites or keep them in
  version control: exported as JSON (an object of key to value) or YAML (a
  flat mapping, each value written as a JSON scalar or list, which YAML
  reads as such), and imported from either.

  Exports hold the settings an admin changed (or, with `all: true`, every
  one), never secrets. Imports go through `Firefly.SiteSettings.update/2`,
  so each value is validated and every change staff-logged; unknown keys,
  secrets and settings pinned by the environment are skipped and reported.
  The YAML read is that subset: `key: value` lines, `#` comments and blank
  lines, a value being a quoted or plain scalar or a `[...]` list.
  """

  alias Firefly.SiteSettings

  @doc "The settings to export, by key (see the moduledoc for `opts`)."
  def export_map(opts \\ []) do
    for definition <- SiteSettings.definitions(),
        not Map.get(definition, :secret, false),
        opts[:all] || SiteSettings.customized?(definition.key),
        into: %{},
        do: {definition.key, SiteSettings.get(definition.key)}
  end

  @doc "The export as `format` (`:json` or `:yaml`)."
  def export(format, opts \\ [])

  def export(:json, opts), do: Jason.encode_to_iodata!(export_map(opts), pretty: true)

  def export(:yaml, opts) do
    lines =
      for {key, value} <- Enum.sort(export_map(opts)), do: [key, ": ", Jason.encode!(value), "\n"]

    ["# Firefly site settings\n" | lines]
  end

  @doc """
  Parses `text` (JSON or YAML, whichever it is) into settings by key:
  `{:ok, map}` or `{:error, message}`.
  """
  def parse(text) when is_binary(text) do
    case String.trim_leading(text) do
      "{" <> _ ->
        case Jason.decode(text) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _invalid -> {:error, "That isn't valid JSON."}
        end

      _yaml ->
        parse_yaml(text)
    end
  end

  defp parse_yaml(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} ->
      String.trim(line) == "" or String.starts_with?(String.trim(line), "#")
    end)
    |> Enum.reduce_while({:ok, %{}}, fn {line, n}, {:ok, acc} ->
      case Regex.run(~r/^([a-z0-9_]+):\s*(.*)$/, String.trim_trailing(line)) do
        [_, key, value] -> {:cont, {:ok, Map.put(acc, key, scalar(String.trim(value)))}}
        nil -> {:halt, {:error, "Line #{n} isn't a `key: value` setting."}}
      end
    end)
  end

  defp scalar(""), do: ""

  defp scalar(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _plain} -> value |> String.trim_leading("'") |> String.trim_trailing("'")
    end
  end

  @doc """
  Imports `settings` (by key) as `admin`: `{:ok, %{changed: keys,
  skipped: keys}}` or `{:error, errors}` (by key; nothing is saved then).
  """
  def import(settings, admin) when is_map(settings) do
    importable =
      for definition <- SiteSettings.definitions(),
          not Map.get(definition, :secret, false),
          is_nil(SiteSettings.env_override(definition.key)),
          into: MapSet.new(),
          do: definition.key

    {take, skip} = Enum.split_with(settings, fn {key, _value} -> key in importable end)
    params = Map.new(take, fn {key, value} -> {key, form_value(value)} end)

    with {:ok, changes} <- SiteSettings.update(params, admin) do
      {:ok,
       %{
         changed: changes |> Map.keys() |> Enum.sort(),
         skipped: skip |> Enum.map(&elem(&1, 0)) |> Enum.sort()
       }}
    end
  end

  # What a form would post for the value.
  defp form_value(value) when is_list(value), do: Enum.map_join(value, ",", &to_string/1)
  defp form_value(value), do: to_string(value)
end
