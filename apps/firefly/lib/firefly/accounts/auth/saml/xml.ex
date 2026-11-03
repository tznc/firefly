defmodule Firefly.Accounts.Auth.SAML.XML do
  @moduledoc """
  The XML that SAML needs: parsing untrusted documents into elements with
  their namespaces resolved, finding things in them, and exclusive XML
  canonicalization (the `xml-exc-c14n#` algorithm, without comments) for
  signatures (see `Firefly.Accounts.Auth.SAML.Signature`).

  Parsing is Saxy's, which makes no atoms from the document (unlike xmerl,
  whose tag atoms let anyone exhaust the atom table) and never fetches or
  expands external entities. Documents with a DTD are refused outright
  (SAML has no use for one), as are oversized ones and undeclared prefixes.

  An element is a map: `name` (as written, with its prefix), `prefix`,
  `local`, `ns` (its namespace's URI, `""` for none), `attrs` (`{name,
  value}`, namespace declarations left out), `scope` (the in-scope
  namespaces, prefix to URI, `""` for the default) and `children`
  (elements and text).
  """

  @max_bytes 512_000
  @xml_ns "http://www.w3.org/XML/1998/namespace"

  @type element :: %{
          name: String.t(),
          prefix: String.t(),
          local: String.t(),
          ns: String.t(),
          attrs: [{String.t(), String.t()}],
          scope: %{optional(String.t()) => String.t()},
          children: [element() | String.t()]
        }

  @doc "Parses `xml`: `{:ok, root}` or `{:error, :invalid_xml}`."
  @spec parse(binary()) :: {:ok, element()} | {:error, :invalid_xml}
  def parse(xml) when is_binary(xml) and byte_size(xml) <= @max_bytes do
    # Line ends are normalized as an XML processor must (Saxy doesn't).
    xml = xml |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

    with false <- String.contains?(xml, "<!DOCTYPE") or String.contains?(xml, "<!ENTITY"),
         {:ok, simple} <- Saxy.SimpleForm.parse_string(xml) do
      {:ok, build(simple, %{"xml" => @xml_ns})}
    else
      _invalid -> {:error, :invalid_xml}
    end
  catch
    :undeclared_prefix -> {:error, :invalid_xml}
  end

  def parse(_xml), do: {:error, :invalid_xml}

  defp build({name, attrs, children}, parent_scope) do
    {declarations, attrs} = Enum.split_with(attrs, fn {key, _} -> namespace_declaration?(key) end)

    scope =
      Enum.reduce(declarations, parent_scope, fn
        {"xmlns", uri}, scope -> Map.put(scope, "", uri)
        {"xmlns:" <> prefix, uri}, scope -> Map.put(scope, prefix, uri)
      end)

    {prefix, local} = split(name)
    Enum.each(attrs, fn {key, _} -> attr_namespace(key, scope) end)

    %{
      name: name,
      prefix: prefix,
      local: local,
      ns: resolve(prefix, scope),
      attrs: attrs,
      scope: scope,
      children: Enum.map(children, &build_child(&1, scope))
    }
  end

  defp build_child(text, _scope) when is_binary(text), do: text
  defp build_child(element, scope), do: build(element, scope)

  defp namespace_declaration?(key), do: key == "xmlns" or String.starts_with?(key, "xmlns:")

  defp split(name) do
    case String.split(name, ":", parts: 2) do
      [prefix, local] -> {prefix, local}
      [local] -> {"", local}
    end
  end

  defp resolve("", scope), do: Map.get(scope, "", "")

  defp resolve(prefix, scope) do
    case Map.fetch(scope, prefix) do
      {:ok, uri} when uri != "" -> uri
      _undeclared -> throw(:undeclared_prefix)
    end
  end

  # Unprefixed attributes are in no namespace (not the default one).
  defp attr_namespace(key, scope) do
    case split(key) do
      {"", _local} -> ""
      {prefix, _local} -> resolve(prefix, scope)
    end
  end

  ## Finding things

  @doc "`element`'s child elements, all or only those named `local` in namespace `ns`."
  def children(element), do: Enum.filter(element.children, &is_map/1)

  def children(element, ns, local),
    do: Enum.filter(children(element), &(&1.ns == ns and &1.local == local))

  @doc "The only child element named `local` in `ns`: `{:ok, child}`, else `:error` (none or several)."
  def child(element, ns, local) do
    case children(element, ns, local) do
      [child] -> {:ok, child}
      _none_or_more -> :error
    end
  end

  @doc "Every element in the tree, `element` first."
  def elements(element), do: [element | Enum.flat_map(children(element), &elements/1)]

  @doc "The value of `element`'s attribute `name` (as written), or nil."
  def attr(element, name) do
    Enum.find_value(element.attrs, fn {key, value} -> if key == name, do: value end)
  end

  @doc "`element`'s text: all its text, its descendants' included, trimmed."
  def text(element), do: element |> raw_text() |> String.trim()

  defp raw_text(text) when is_binary(text), do: text
  defp raw_text(element), do: Enum.map_join(element.children, &raw_text/1)

  ## Exclusive canonicalization

  @doc """
  `element` in exclusive canonical form (without comments, which the
  parser drops anyway), as a signature hashes it. `inclusive` is the
  `InclusiveNamespaces` prefix list (`"#default"` for the default
  namespace), whose prefixes are rendered wherever they're in scope.
  """
  @spec canonicalize(element(), [String.t()]) :: iodata()
  def canonicalize(element, inclusive \\ []) do
    inclusive = Enum.map(inclusive, &if(&1 == "#default", do: "", else: &1))
    canonical(element, inclusive, %{})
  end

  defp canonical(text, _inclusive, _rendered) when is_binary(text), do: escape_text(text)

  defp canonical(element, inclusive, rendered) do
    declarations = declarations(element, inclusive, rendered)
    rendered = Enum.into(declarations, rendered)

    [
      "<",
      element.name,
      Enum.map(declarations, fn
        {"", uri} -> [" xmlns=\"", escape_attr(uri), "\""]
        {prefix, uri} -> [" xmlns:", prefix, "=\"", escape_attr(uri), "\""]
      end),
      element.attrs
      |> Enum.sort_by(fn {key, _} -> {attr_namespace(key, element.scope), local_name(key)} end)
      |> Enum.map(fn {key, value} -> [" ", key, "=\"", escape_attr(value), "\""] end),
      ">",
      Enum.map(element.children, &canonical(&1, inclusive, rendered)),
      "</",
      element.name,
      ">"
    ]
  end

  # The namespaces this element visibly uses (its own prefix, its
  # attributes'), and the inclusive ones in scope, that no output ancestor
  # already declared the same way.
  defp declarations(element, inclusive, rendered) do
    used =
      element.attrs
      |> Enum.map(fn {key, _} -> elem(split(key), 0) end)
      |> Enum.reject(&(&1 in ["", "xml"]))

    inclusive = Enum.filter(inclusive, &Map.has_key?(element.scope, &1))

    [element.prefix | used]
    |> Enum.concat(inclusive)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, Map.get(element.scope, &1, "")})
    |> Enum.reject(fn
      {"", ""} -> Map.get(rendered, "", "") == ""
      {prefix, uri} -> Map.get(rendered, prefix) == uri
    end)
  end

  defp local_name(key), do: elem(split(key), 1)

  defp escape_text(text) do
    for <<char::utf8 <- text>>, into: "" do
      case char do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?> -> "&gt;"
        ?\r -> "&#xD;"
        char -> <<char::utf8>>
      end
    end
  end

  defp escape_attr(value) do
    for <<char::utf8 <- value>>, into: "" do
      case char do
        ?& -> "&amp;"
        ?< -> "&lt;"
        ?" -> "&quot;"
        ?\t -> "&#x9;"
        ?\n -> "&#xA;"
        ?\r -> "&#xD;"
        char -> <<char::utf8>>
      end
    end
  end
end
