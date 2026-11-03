defmodule Firefly.AI.SemanticSearch do
  @moduledoc """
  Search by meaning, with post embeddings (see `Firefly.AI.Embeddings`).

    * `run/3` is hybrid search, the search page's "Semantic" toggle: the
      full-text results (`Firefly.Discussion.Search`) and the posts nearest
      the query's embedding (cosine distance), each ranked, fused by
      reciprocal rank fusion (each post scores the sum of `1 / (60 +
      rank)` over the lists it's in). Both lists start from the same
      `Firefly.Discussion.Search.scope/2`, so they find exactly what
      full-text search may (published posts in threads the searcher may
      read, with the filters), only more of it. Without terms, ordered by
      date, or when embedding the query fails, it's plain full-text search.
    * `related/3` is the topics nearest a topic (by their first posts),
      for the bottom of a topic page, among those the reader may read.
  """

  import Ecto.Query

  alias Firefly.{AI, Repo}
  alias Firefly.AI.{Embeddings, PostEmbedding}
  alias Firefly.Discussion.{Post, Search, Thread}

  @candidates 100
  @k 60
  @page_size 20

  @doc "Whether semantic search is on (the `embeddings` feature)."
  def enabled?, do: AI.available?(nil, "embeddings")

  @doc """
  Hybrid search: `{:semantic, page}` (a page like
  `Firefly.Discussion.Search.run/3`'s) when the embeddings were used, else
  `{:full_text, page}`.
  """
  def run(%Search{} = search, user, page \\ 1) do
    with true <- search.terms != "" and search.order == "relevance",
         model when is_binary(model) <- Embeddings.model(),
         {:ok, vector} <- Embeddings.embed_query(search.terms) do
      ids =
        fuse([
          Search.ranked_ids(search, user, @candidates),
          nearest_ids(search, user, model, vector)
        ])

      page = max(page, 1)

      entries =
        Search.results(
          search,
          user,
          ids |> Enum.drop((page - 1) * @page_size) |> Enum.take(@page_size)
        )

      {:semantic,
       %Scrivener.Page{
         entries: entries,
         page_number: page,
         page_size: @page_size,
         total_entries: length(ids),
         total_pages: max(div(length(ids) + @page_size - 1, @page_size), 1)
       }}
    else
      _no_semantics -> {:full_text, Search.run(search, user, page)}
    end
  end

  defp nearest_ids(search, user, model, vector) do
    search
    |> Search.scope(user)
    |> join(:inner, [p], e in PostEmbedding,
      on: e.post_id == p.id and e.model == ^model,
      as: :embedding
    )
    |> order_by([embedding: e], fragment("? <=> ?", e.embedding, ^vector))
    |> limit(@candidates)
    |> select([p], p.id)
    |> Repo.all()
  end

  @doc "Reciprocal rank fusion of ranked lists of ids: the ids, best first."
  def fuse(lists) do
    lists
    |> Enum.flat_map(&Enum.with_index(&1, 1))
    |> Enum.reduce(%{}, fn {id, rank}, scores ->
      Map.update(scores, id, 1 / (@k + rank), &(&1 + 1 / (@k + rank)))
    end)
    |> Enum.sort_by(fn {id, score} -> {-score, -id} end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Up to `limit` topics nearest `thread` (by their first posts'
  embeddings) that `user` may read, nearest first; none while semantic
  search is off or the topic isn't embedded yet.
  """
  def related(%Thread{} = thread, user, limit \\ 5) do
    with model when is_binary(model) <- Embeddings.model(),
         %PostEmbedding{embedding: vector} <- first_post_embedding(thread, model) do
      %Search{}
      |> Search.scope(user)
      |> Search.first_posts()
      |> join(:inner, [p], e in PostEmbedding,
        on: e.post_id == p.id and e.model == ^model,
        as: :embedding
      )
      |> where([thread: t], t.id != ^thread.id and is_nil(t.merged_into_id))
      |> order_by([embedding: e], fragment("? <=> ?", e.embedding, ^vector))
      |> limit(^limit)
      |> select([thread: t, category: c], {t, c})
      |> Repo.all()
      |> Enum.map(fn {thread, category} -> %{thread | category: category} end)
    else
      _none -> []
    end
  end

  defp first_post_embedding(thread, model) do
    Repo.one(
      from(e in PostEmbedding,
        join: p in Post,
        on: p.id == e.post_id,
        where: p.thread_id == ^thread.id and e.model == ^model,
        order_by: [asc: p.inserted_at, asc: p.id],
        limit: 1
      )
    )
  end
end
