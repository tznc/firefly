defmodule Firefly.Text do
  @moduledoc """
  Text that PostgreSQL can store. `text` and `varchar` can't hold a NUL
  character (`"\\0"`) and `jsonb` refuses `"\\u0000"`, so one NUL in what a
  visitor, a plugin or an import sends would fail the write (or the query)
  with a database error. NUL means nothing in forum text, so the application
  strips it:

    * where input enters: the web endpoint and LiveViews (see
      `FireflyWeb.Plugs.StripNul` and `FireflyWeb.LiveStripNul`), search
      (`Firefly.Discussion.Search`), importers, and what plugins hand back
      (`Firefly.Plugin.Runner`, `Firefly.Plugin.Host`);
    * and, as the last application layer, from changesets
      (`strip_nul_changes/1`): when they cast (`Firefly.Changeset`), and
      again when `Firefly.Repo` writes them, so domain calls that never
      went through the web are covered too.

  The database still refuses a NUL that gets past all of that (a raw
  struct, `insert_all`, a query): `unstorable?/1` recognizes that error, so
  `Firefly.Repo` and the web layer turn it into a clean refusal rather than a
  crash.
  """

  # 22021 character_not_in_repertoire (NUL, or bytes that aren't UTF-8, in
  # text) and 22P05 untranslatable_character ("\u0000" in jsonb).
  @unstorable [:character_not_in_repertoire, :untranslatable_character]

  @doc """
  `term` without NUL characters: in a string, and in the strings (keys and
  values) of maps, lists and keyword lists, recursively. Other terms,
  structs included, are returned as they are.

      iex> Firefly.Text.strip_nul(%{"title" => <<"a", 0, "b">>, "tags" => [<<0>>, "c"]})
      %{"title" => "ab", "tags" => ["", "c"]}

      iex> Firefly.Text.strip_nul(body: <<"x", 0>>, id: 1)
      [body: "x", id: 1]
  """
  @spec strip_nul(term) :: term
  def strip_nul(text) when is_binary(text), do: :binary.replace(text, <<0>>, <<>>, [:global])
  def strip_nul(%_{} = struct), do: struct

  def strip_nul(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {strip_nul(k), strip_nul(v)} end)

  def strip_nul([{key, value} | rest]) when is_atom(key),
    do: [{key, strip_nul(value)} | strip_nul(rest)]

  def strip_nul([head | rest]), do: [strip_nul(head) | strip_nul(rest)]
  def strip_nul(other), do: other

  @doc """
  `changeset` with NUL characters stripped from its changes to text, map
  and array-of-text fields (by their database type, so binary fields, which
  may hold NUL bytes, are left alone), and from those of the changesets
  nested in it (associations, embeds). A schema struct inserted as it is
  (`Repo.insert(%Schema{...})`) has its text fields stripped the same way.
  Anything else is returned as it is.
  """
  @spec strip_nul_changes(term) :: term
  def strip_nul_changes(%Ecto.Changeset{changes: changes, types: types} = changeset) do
    changes =
      Map.new(changes, fn {field, value} -> {field, strip_change(types[field], value)} end)

    %{changeset | changes: changes}
  end

  def strip_nul_changes(%schema{__meta__: %Ecto.Schema.Metadata{}} = struct) do
    Enum.reduce(schema.__schema__(:fields), struct, fn field, struct ->
      Map.update!(struct, field, &strip_change(schema.__schema__(:type, field), &1))
    end)
  end

  def strip_nul_changes(other), do: other

  defp strip_change(_type, %Ecto.Changeset{} = changeset), do: strip_nul_changes(changeset)

  defp strip_change(_type, [%Ecto.Changeset{} | _] = changesets),
    do: Enum.map(changesets, &strip_nul_changes/1)

  defp strip_change(type, value), do: if(textual?(type), do: strip_nul(value), else: value)

  defp textual?(nil), do: false
  defp textual?({kind, _}) when kind in [:assoc, :embed], do: false

  defp textual?(type) do
    case Ecto.Type.type(type) do
      primitive when primitive in [:string, :map, {:array, :string}, {:array, :map}] -> true
      {:map, _values} -> true
      _other -> false
    end
  end

  @doc """
  Whether `exception` is PostgreSQL refusing text it can't store (a NUL,
  or bytes that aren't UTF-8).
  """
  @spec unstorable?(Exception.t()) :: boolean
  def unstorable?(%Postgrex.Error{postgres: %{code: code}}), do: code in @unstorable
  def unstorable?(_exception), do: false
end
