defmodule Firefly.AI.Embeddings do
  @moduledoc """
  Embeddings of posts for semantic search (the `embeddings` feature; see
  `Firefly.AI.SemanticSearch`), kept in `ai_post_embeddings` (pgvector).

  A topic's first post is embedded with its title. Posts are embedded in
  the background as they're published or edited (`embed_later/1`), and
  `run_due/0` (every scheduler tick) embeds, in batches of 50, those
  still missing: older posts, posts whose text changed (the stored hash
  no longer matches) and, after the provider's model changed, everything
  again. Only published posts are embedded; search filters by permission
  when it reads them, like full-text search.
  """

  import Ecto.Query

  alias Firefly.{AI, Repo}
  alias Firefly.AI.{FeatureSetting, PostEmbedding}
  alias Firefly.Discussion.{Post, Thread}

  @batch 50
  @batches_per_run 4
  # Embedding models take a few thousand tokens.
  @max_chars 8_000

  @doc "The embedding model in use: the `embeddings` provider's, or nil while it's off."
  def model do
    if AI.available?(nil, "embeddings") do
      case Repo.one(
             from(f in FeatureSetting, where: f.feature == "embeddings", preload: :provider)
           ) do
        %FeatureSetting{provider: %{} = provider} -> provider.embedding_model || provider.model
        _off -> nil
      end
    end
  end

  @doc "Embeds `post` in the background (after it's published or edited), when embeddings are on."
  def embed_later(%Post{} = post) do
    if model(), do: AI.background(fn -> embed([post.id]) end)
    :ok
  end

  @doc """
  Embeds the next batches of posts missing an up-to-date embedding: up to
  #{@batches_per_run} batches of #{@batch}. Returns how many were embedded.
  """
  def run_due do
    case model() do
      nil -> 0
      model -> run_batches(model, @batches_per_run, 0)
    end
  end

  defp run_batches(_model, 0, count), do: count

  defp run_batches(model, left, count) do
    case due(model) do
      [] ->
        count

      ids ->
        case embed(ids) do
          {:ok, n} -> run_batches(model, left - 1, count + n)
          {:error, _reason} -> count
        end
    end
  end

  # Published posts without an embedding by `model` of their current text.
  defp due(model) do
    Repo.all(
      from(p in Post,
        left_join: e in PostEmbedding,
        on: e.post_id == p.id,
        where: is_nil(p.deleted_at) and is_nil(p.queued_at),
        where:
          is_nil(e.post_id) or e.model != ^model or
            e.source_hash != fragment("sha256(convert_to(?, 'UTF8'))", p.body),
        order_by: [desc: p.id],
        limit: @batch,
        select: p.id
      )
    )
  end

  @doc "Embeds the posts `ids` now: `{:ok, count}` or `{:error, reason}`."
  def embed(ids) do
    posts =
      Repo.all(
        from(p in Post,
          join: t in Thread,
          on: t.id == p.thread_id,
          where: p.id in ^ids and is_nil(p.deleted_at) and is_nil(p.queued_at),
          select:
            {p.id, p.body, t.title,
             fragment(
               "(SELECT min(f.id) FROM forums_posts f WHERE f.thread_id = ?) = ?",
               t.id,
               p.id
             )}
        )
      )

    with true <- posts != [] || {:ok, 0},
         model when is_binary(model) <- model() || {:error, :disabled},
         {:ok, %{vectors: vectors}} <- AI.embed("embeddings", Enum.map(posts, &text/1)) do
      now = NaiveDateTime.utc_now()

      rows =
        for {{id, body, _title, _first?}, vector} <- Enum.zip(posts, vectors) do
          %{
            post_id: id,
            model: model,
            source_hash: :crypto.hash(:sha256, body),
            embedding: Pgvector.new(vector),
            updated_at: now
          }
        end

      Repo.insert_all(PostEmbedding, rows,
        on_conflict: {:replace, [:model, :source_hash, :embedding, :updated_at]},
        conflict_target: :post_id
      )

      {:ok, length(rows)}
    end
  end

  defp text({_id, body, title, true}), do: String.slice(title <> "\n\n" <> body, 0, @max_chars)
  defp text({_id, body, _title, _reply}), do: String.slice(body, 0, @max_chars)

  @doc "Embeds `text` (a search query) with the model in use: `{:ok, vector}` or `{:error, reason}`."
  def embed_query(text) do
    with {:ok, %{vectors: [vector]}} <-
           AI.embed("embeddings", [String.slice(text, 0, @max_chars)]),
         do: {:ok, Pgvector.new(vector)}
  end
end
