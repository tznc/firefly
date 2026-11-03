defmodule Firefly.Accounts.Auth.LDAP.Filter do
  @moduledoc """
  LDAP search filters (RFC 4515 strings, as admins write them) turned into
  `:eldap`'s, with placeholders such as `%{username}` filled in.

  The placeholders are filled in after parsing, as literal values: a
  username with `*`, `)` or `\\` in it can't change the filter's meaning
  (LDAP injection), it's only ever compared with as it is.
  """

  @doc """
  Parses `template`, replacing each `%{name}` in its values with
  `values[name]`: `{:ok, filter}` or `{:error, :invalid_filter}`.
  """
  def parse(template, values) when is_binary(template) do
    case filter(String.trim(template), values) do
      {:ok, filter, ""} -> {:ok, filter}
      _invalid -> {:error, :invalid_filter}
    end
  catch
    :invalid -> {:error, :invalid_filter}
  end

  defp filter("(" <> rest, values) do
    {filter, rest} = component(rest, values)

    case rest do
      ")" <> rest -> {:ok, filter, rest}
      _unclosed -> throw(:invalid)
    end
  end

  defp filter(_text, _values), do: throw(:invalid)

  defp component("&" <> rest, values), do: list(rest, values, &:eldap.and/1)
  defp component("|" <> rest, values), do: list(rest, values, &:eldap.or/1)

  defp component("!" <> rest, values) do
    {:ok, filter, rest} = filter(rest, values)
    {:eldap.not(filter), rest}
  end

  defp component(text, values) do
    case Regex.run(~r/^([A-Za-z0-9;.-]+)(=|>=|<=|~=)([^)]*)/, text) do
      [whole, attribute, operator, value] ->
        rest = binary_part(text, byte_size(whole), byte_size(text) - byte_size(whole))
        {item(String.to_charlist(attribute), operator, value, values), rest}

      nil ->
        throw(:invalid)
    end
  end

  defp list(text, values, combine, acc \\ [])

  defp list("(" <> _ = text, values, combine, acc) do
    {:ok, filter, rest} = filter(text, values)
    list(rest, values, combine, [filter | acc])
  end

  defp list(_rest, _values, _combine, []), do: throw(:invalid)
  defp list(rest, _values, combine, acc), do: {combine.(Enum.reverse(acc)), rest}

  defp item(attribute, "=", "*", _values), do: :eldap.present(attribute)

  defp item(attribute, "=", value, values) do
    case String.split(value, "*") do
      [single] -> :eldap.equalityMatch(attribute, fill(single, values))
      parts -> :eldap.substrings(attribute, substrings(parts, values))
    end
  end

  defp item(attribute, ">=", value, values),
    do: :eldap.greaterOrEqual(attribute, fill(value, values))

  defp item(attribute, "<=", value, values),
    do: :eldap.lessOrEqual(attribute, fill(value, values))

  defp item(attribute, "~=", value, values),
    do: :eldap.approxMatch(attribute, fill(value, values))

  defp substrings(parts, values) do
    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.reject(fn {part, _index} -> part == "" end)
    |> Enum.map(fn
      {part, 0} -> {:initial, fill(part, values)}
      {part, ^last} -> {:final, fill(part, values)}
      {part, _middle} -> {:any, fill(part, values)}
    end)
  end

  # The template's escapes (`\\2a`) decoded, then the placeholders filled in
  # as they are.
  defp fill(text, values) do
    ~r/%\{(\w+)\}/
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn piece ->
      case Regex.run(~r/^%\{(\w+)\}$/, piece) do
        [_, name] -> Map.get(values, name) || throw(:invalid)
        nil -> unescape(piece)
      end
    end)
    |> :binary.bin_to_list()
  end

  defp unescape(text) do
    Regex.replace(~r/\\([0-9A-Fa-f]{2})/, text, fn _, hex -> <<String.to_integer(hex, 16)>> end)
  end
end
