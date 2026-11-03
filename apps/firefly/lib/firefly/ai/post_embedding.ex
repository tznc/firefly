defmodule Firefly.AI.PostEmbedding do
  @moduledoc """
  A post's embedding for semantic search (see `Firefly.AI.Embeddings`):
  the vector, the model that made it and the hash of the text it embeds.
  """
  use Ecto.Schema

  @primary_key {:post_id, :id, autogenerate: false}
  schema "ai_post_embeddings" do
    field(:model, :string)
    field(:source_hash, :binary)
    field(:embedding, Pgvector.Ecto.Vector)

    timestamps(type: :naive_datetime_usec, inserted_at: false)
  end
end
