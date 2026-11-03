defmodule FireflyImport.Sources.GitHub do
  @moduledoc """
  Imports a GitHub repository's Discussions through GitHub's GraphQL API.
  Options:

    * `--repo owner/name` (required)
    * `--token TOKEN` (required): a GitHub token that can read the
      repository (a fine-grained one with Discussions read access, or a
      classic one with `repo` or `public_repo`)
    * `--api-url`: the GraphQL endpoint (default
      `https://api.github.com/graphql`; GitHub Enterprise has its own)

  What it imports: discussion categories (Q&A ones accept answers),
  discussions (closed and locked ones closed) with their comments and
  replies (each a post, in order), reactions as likes, accepted answers,
  and their authors: placeholder accounts named by their GitHub login,
  with their public email when they show one, and linked to their GitHub
  account (`user_identities`, provider `github`), so logging in with GitHub
  gets theirs back (an account already linked to it, or with that email,
  is theirs). Up to 100 comments per discussion, replies per comment and
  reactions per post are read.
  """

  @behaviour FireflyImport.Source

  @api "https://api.github.com/graphql"
  @page 25

  @author "author { login ... on User { databaseId email name } }"
  @reactions "reactions(first: 100) { nodes { user { login ... on User { databaseId email name } } } }"

  @query """
  query($owner: String!, $name: String!, $cursor: String) {
    repository(owner: $owner, name: $name) {
      discussionCategories(first: 100) { nodes { id name description isAnswerable } }
      discussions(first: #{@page}, after: $cursor, orderBy: {field: CREATED_AT, direction: ASC}) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id number title body createdAt updatedAt lastEditedAt closed locked
          category { id }
          answer { id }
          #{@author}
          #{@reactions}
          comments(first: 100) {
            nodes {
              id body createdAt lastEditedAt
              #{@author}
              #{@reactions}
              replies(first: 100) {
                nodes { id body createdAt lastEditedAt #{@author} #{@reactions} }
              }
            }
          }
        }
      }
    }
  }
  """

  @impl true
  def name, do: "github"

  @impl true
  def switches, do: [repo: :string, token: :string, api_url: :string]

  @impl true
  def usage do
    """
      --repo OWNER/NAME  the repository
      --token TOKEN      a GitHub token that can read it
      --api-url URL      the GraphQL API (default #{@api})
    """
  end

  @impl true
  def open(opts) do
    with {:ok, owner, name} <- repo(opts[:repo]),
         token when is_binary(token) <- opts[:token] || {:error, "--token is required"},
         {:ok, categories, discussions} <- fetch(opts[:api_url] || @api, token, owner, name) do
      {:ok, %{categories: categories, discussions: discussions}}
    end
  end

  @impl true
  def close(_state), do: :ok

  @impl true
  def stream(state, :users) do
    state.discussions
    |> Enum.flat_map(fn discussion ->
      Enum.flat_map([discussion | posts(discussion)], &people/1)
    end)
    |> Enum.uniq_by(& &1["login"])
    |> Enum.map(fn person ->
      %{
        id: person["login"],
        username: person["login"],
        name: person["name"],
        email: blank(person["email"]),
        identities:
          if(person["databaseId"],
            do: [
              %{provider: "github", uid: person["databaseId"], info: %{nickname: person["login"]}}
            ],
            else: []
          )
      }
    end)
  end

  def stream(state, :categories) do
    state.categories
    |> Enum.with_index()
    |> Enum.map(fn {category, position} ->
      %{
        id: category["id"],
        title: category["name"],
        description: blank(category["description"]),
        position: position,
        allow_accepted_answers: category["isAnswerable"] == true
      }
    end)
  end

  def stream(state, :topics) do
    Enum.map(state.discussions, fn discussion ->
      %{
        id: discussion["id"],
        category_id: get_in(discussion, ["category", "id"]),
        title: discussion["title"],
        closed_at:
          if(discussion["closed"] or discussion["locked"], do: time(discussion["updatedAt"])),
        created_at: time(discussion["createdAt"]),
        updated_at: time(discussion["updatedAt"])
      }
    end)
  end

  # The discussion's own text, then its comments and replies, in order.
  def stream(state, :posts) do
    Enum.flat_map(state.discussions, fn discussion ->
      Enum.map([discussion | posts(discussion)], fn post ->
        %{
          id: post_id(discussion, post),
          topic_id: discussion["id"],
          user_id: login(post),
          body: post["body"] || "",
          created_at: time(post["createdAt"]),
          edited_at: time(post["lastEditedAt"])
        }
      end)
    end)
  end

  def stream(state, :likes) do
    for discussion <- state.discussions,
        post <- [discussion | posts(discussion)],
        login <- post |> reactors() |> Enum.uniq(),
        do: %{
          post_id: post_id(discussion, post),
          user_id: login,
          created_at: time(post["createdAt"])
        }
  end

  def stream(state, :solved) do
    for %{"answer" => %{"id" => answer}} = discussion <- state.discussions,
        do: %{topic_id: discussion["id"], post_id: answer}
  end

  def stream(_state, _kind), do: []

  ## The API

  defp repo(repo) do
    case String.split(repo || "", "/") do
      [owner, name] when owner != "" and name != "" -> {:ok, owner, name}
      _ -> {:error, "--repo must be owner/name"}
    end
  end

  # Every category and discussion, page by page.
  defp fetch(url, token, owner, name, cursor \\ nil, acc \\ []) do
    variables = %{owner: owner, name: name, cursor: cursor}

    case Req.post(url,
           json: %{query: @query, variables: variables},
           auth: {:bearer, token},
           headers: [{"user-agent", "Firefly importer"}],
           retry: :transient
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{} = repository}}}} ->
        discussions = repository["discussions"]
        acc = acc ++ discussions["nodes"]
        categories = repository["discussionCategories"]["nodes"]

        if discussions["pageInfo"]["hasNextPage"],
          do: fetch(url, token, owner, name, discussions["pageInfo"]["endCursor"], acc),
          else: {:ok, categories, acc}

      {:ok, %{body: %{"errors" => [%{"message" => message} | _]}}} ->
        {:error, "GitHub: #{message}"}

      {:ok, %{status: status}} ->
        {:error, "GitHub answered with HTTP #{status}"}

      {:error, error} ->
        {:error, "GitHub couldn't be reached: #{Exception.message(error)}"}
    end
  end

  ## Helpers

  defp posts(discussion) do
    discussion
    |> get_in(["comments", "nodes"])
    |> List.wrap()
    |> Enum.flat_map(&[&1 | List.wrap(get_in(&1, ["replies", "nodes"]))])
    |> Enum.sort_by(& &1["createdAt"])
  end

  # The discussion's own text has the discussion's id; comments their own.
  defp post_id(%{"id" => id}, %{"id" => id}), do: id <> ":body"
  defp post_id(_discussion, post), do: post["id"]

  defp people(post), do: Enum.reject([post["author"] | reacting(post)], &is_nil/1)

  defp reactors(post), do: for(%{"login" => login} <- reacting(post), do: login)

  # Who reacted to the post (a deleted account is nobody).
  defp reacting(post),
    do:
      for(node <- List.wrap(get_in(post, ["reactions", "nodes"])), user = node["user"], do: user)

  # A deleted account's posts have no author.
  defp login(post), do: get_in(post, ["author", "login"])

  defp time(nil), do: nil

  defp time(iso) do
    {:ok, at, _offset} = DateTime.from_iso8601(iso)
    at
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end
