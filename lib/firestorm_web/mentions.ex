defmodule FirestormWeb.Mentions do
  @moduledoc """
  `@username` mentions and `#category-slug` links in posts.

  Both are found in the post's Markdown AST, in plain text only: never inside
  code spans, code blocks, raw HTML or links (so a quote's `[@alice said:]`
  attribution stays as it is). Rendering (see `FirestormWeb.Markdown`) turns
  the ones that name an existing user or category into links, as AST link
  nodes, so the text goes through the normal renderer and sanitizer.

  Mentions inside block quotes are linked but don't notify: quoting a post
  shouldn't ping everyone that post mentioned.
  """

  import Ecto.Changeset, only: [validate_change: 3]

  alias FirestormWeb.Forums
  alias FirestormWeb.Web.Paths

  # An `@name` or `#name` not preceded by a word character, so emails
  # ("bob@example.com") and anchors ("page#top") don't count.
  @token ~r/(?<![\w@#\/&])[@#][A-Za-z0-9_-]+/u

  # Nodes whose text is never scanned.
  @unscanned [MDEx.Link, MDEx.Image, MDEx.WikiLink, MDEx.Code, MDEx.CodeBlock, MDEx.HtmlBlock]

  @doc "How many users a post may mention (the `max_mentions` site setting)."
  def max_mentions, do: FirestormWeb.SiteSettings.get("max_mentions")

  @doc """
  The usernames a post mentions (downcased, unique, in order), leaving out
  mentions inside block quotes.
  """
  @spec usernames(String.t() | nil) :: [String.t()]
  def usernames(nil), do: []

  def usernames(body) when is_binary(body) do
    body
    |> parse()
    |> texts([MDEx.BlockQuote | @unscanned])
    |> names("@")
  end

  @doc "Adds a `:body` error when the post mentions more than `max_mentions/0` users."
  def validate_count(%Ecto.Changeset{} = changeset) do
    validate_change(changeset, :body, fn :body, body ->
      max = max_mentions()

      if length(usernames(body)) > max,
        do: [body: {"can mention at most %{count} users", count: max}],
        else: []
    end)
  end

  @doc """
  Links the mentions and category references in a parsed document to the
  user profiles and categories they name. Unknown names stay plain text.
  """
  @spec link(MDEx.Document.t()) :: MDEx.Document.t()
  def link(%MDEx.Document{} = document) do
    texts = texts(document, @unscanned)
    users = texts |> names("@") |> Forums.users_by_username()
    categories = texts |> names("#") |> Forums.categories_by_slug()

    if users == %{} and categories == %{} do
      document
    else
      # Absolute, so the links also work in notification emails.
      targets = %{"@" => {users, &Paths.user_url/1}, "#" => {categories, &Paths.category_url/1}}
      link_node(document, targets)
    end
  end

  @doc false
  def parse(body), do: MDEx.parse_document!(body, FirestormWeb.Markdown.options())

  defp texts(%MDEx.Text{literal: literal}, _skip), do: [literal]

  defp texts(%type{nodes: nodes}, skip),
    do: if(type in skip, do: [], else: Enum.flat_map(nodes, &texts(&1, skip)))

  defp texts(_node, _skip), do: []

  defp names(texts, sigil) do
    for text <- texts,
        [<<^sigil::binary-size(1), name::binary>>] <- Regex.scan(@token, text),
        uniq: true,
        do: String.downcase(name)
  end

  defp link_node(%type{} = node, _targets) when type in @unscanned, do: node

  defp link_node(%{nodes: nodes} = node, targets),
    do: %{node | nodes: Enum.flat_map(nodes, &link_child(&1, targets))}

  defp link_node(node, _targets), do: node

  defp link_child(%MDEx.Text{literal: literal}, targets) do
    @token
    |> Regex.split(literal, include_captures: true, trim: true)
    |> Enum.map(&link_text(&1, targets))
  end

  defp link_child(node, targets), do: [link_node(node, targets)]

  defp link_text(<<sigil::binary-size(1), name::binary>> = text, targets)
       when sigil in ["@", "#"] do
    {found, path} = Map.fetch!(targets, sigil)

    case Map.fetch(found, String.downcase(name)) do
      {:ok, target} -> %MDEx.Link{url: path.(target), nodes: [%MDEx.Text{literal: text}]}
      :error -> %MDEx.Text{literal: text}
    end
  end

  defp link_text(text, _targets), do: %MDEx.Text{literal: text}
end
