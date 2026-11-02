defmodule FirestormWeb.Plugin.Settings do
  @moduledoc """
  A plugin's settings: typed definitions from its manifest (see
  `FirestormWeb.Plugin.Manifest`), values staff set at
  `/staff/plugins/:id`. Only values that differ from the default are
  stored, so a plugin upgrade that changes a default takes effect; a stored
  value the new version no longer accepts falls back to the default.
  """

  @types ~w(string text integer boolean enum)
  @definition_keys ~w(key type default label help min max choices)
  @key_format ~r/^[a-z][a-z0-9_]{0,39}$/

  @doc false
  def check_definition(%{"key" => key, "type" => type} = definition)
      when is_binary(key) and type in @types do
    built = definition(definition)

    # The first problem, if any: later checks assume the earlier passed.
    Enum.find_value(
      [&key_format/2, &known_keys/2, &texts/2, &choices/2, &bounds/2, &default/2],
      [],
      fn check ->
        case check.(definition, built) do
          :ok -> nil
          problem -> ["setting \"#{key}\" #{problem}"]
        end
      end
    )
  end

  def check_definition(%{"key" => key}) when is_binary(key),
    do: ["setting \"#{key}\" must have a type: #{Enum.join(@types, ", ")}"]

  def check_definition(_definition), do: ["each setting must have a key and a type"]

  defp key_format(_definition, %{key: key}),
    do:
      if(key =~ @key_format, do: :ok, else: "must have a key of lowercase letters, digits and _")

  defp known_keys(definition, _built) do
    case Map.keys(definition) -- @definition_keys do
      [] -> :ok
      unknown -> "has unknown keys #{Enum.join(unknown, ", ")}"
    end
  end

  defp texts(_definition, %{label: label, help: help}),
    do: if(is_binary(label) and is_binary(help), do: :ok, else: "needs text label and help")

  defp choices(_definition, %{type: "enum", choices: choices}) do
    if is_list(choices) and choices != [] and Enum.all?(choices, &is_binary/1),
      do: :ok,
      else: "needs a list of choices"
  end

  defp choices(_definition, _built), do: :ok

  defp bounds(_definition, %{type: "integer", min: min, max: max}) do
    if Enum.all?([min, max], &(is_nil(&1) or is_integer(&1))),
      do: :ok,
      else: "needs whole numbers for min and max"
  end

  defp bounds(_definition, _built), do: :ok

  defp default(definition, built) do
    with true <- Map.has_key?(definition, "default"),
         {:ok, _} <- cast(built, built.default) do
      :ok
    else
      false -> "needs a default"
      {:error, message} -> "needs a valid default: it #{message}"
    end
  end

  @doc false
  def definition(definition) do
    %{
      key: definition["key"],
      type: definition["type"],
      default: definition["default"],
      label: Map.get(definition, "label", definition["key"]),
      help: Map.get(definition, "help", ""),
      min: definition["min"],
      max: definition["max"],
      choices: definition["choices"]
    }
  end

  @doc false
  def to_map(definition), do: Map.reject(definition, fn {_key, value} -> is_nil(value) end)

  @doc "Every setting's current value: the stored one if still valid, else the default."
  def values(definitions, stored) do
    Map.new(definitions, fn definition ->
      with {:ok, value} <- Map.fetch(stored || %{}, definition.key),
           {:ok, value} <- cast(definition, value) do
        {definition.key, value}
      else
        _unset_or_invalid -> {definition.key, definition.default}
      end
    end)
  end

  @doc """
  Casts form `params` (key to value) for `definitions`: `{:ok, stored}`,
  the values to store (those that differ from their defaults), or
  `{:error, errors}` by key.
  """
  def cast_all(definitions, params) do
    {values, errors} =
      Enum.reduce(definitions, {%{}, %{}}, fn definition, {values, errors} ->
        raw = Map.get(params, definition.key, if(definition.type == "boolean", do: "false"))

        case cast(definition, raw) do
          {:ok, value} when value == definition.default -> {values, errors}
          {:ok, value} -> {Map.put(values, definition.key, value), errors}
          {:error, message} -> {values, Map.put(errors, definition.key, message)}
        end
      end)

    if errors == %{}, do: {:ok, values}, else: {:error, errors}
  end

  @doc "Casts one value (from a form or JSON) for its definition."
  def cast(%{type: "boolean"}, value) when value in [true, "true"], do: {:ok, true}
  def cast(%{type: "boolean"}, value) when value in [false, "false"], do: {:ok, false}
  def cast(%{type: "boolean"}, _value), do: {:error, "must be on or off"}

  def cast(%{type: "integer"} = definition, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> cast(definition, n)
      _ -> {:error, "must be a whole number"}
    end
  end

  def cast(%{type: "integer"} = definition, value) when is_integer(value) do
    cond do
      definition.min && value < definition.min -> {:error, "must be at least #{definition.min}"}
      definition.max && value > definition.max -> {:error, "must be at most #{definition.max}"}
      true -> {:ok, value}
    end
  end

  def cast(%{type: "string"}, value) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) > 500 or String.contains?(value, "\n"),
      do: {:error, "must be one line of at most 500 characters"},
      else: {:ok, value}
  end

  def cast(%{type: "text"}, value) when is_binary(value) do
    if String.length(value) > 5_000,
      do: {:error, "must be at most 5000 characters"},
      else: {:ok, String.trim(value)}
  end

  def cast(%{type: "enum", choices: choices}, value) when is_binary(value) do
    if value in choices,
      do: {:ok, value},
      else: {:error, "must be one of #{Enum.join(choices, ", ")}"}
  end

  def cast(_definition, _value), do: {:error, "is invalid"}
end
