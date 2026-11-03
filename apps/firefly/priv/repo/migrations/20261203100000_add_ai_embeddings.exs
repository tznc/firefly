defmodule Firefly.Repo.Migrations.AddAIEmbeddings do
  use Ecto.Migration

  # Semantic search (see Firefly.AI.SemanticSearch): the pgvector extension
  # and an embedding per post. The column has no fixed size, so any
  # embedding model fits; search compares only embeddings of the current
  # model, by exact cosine distance.
  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create table(:ai_post_embeddings, primary_key: false) do
      add :post_id, references(:forums_posts, on_delete: :delete_all), primary_key: true
      # The model that made it: a new model's embeddings replace these.
      add :model, :string, null: false
      # The text's hash: an edit makes the embedding stale.
      add :source_hash, :binary, null: false
      add :embedding, :vector, null: false

      timestamps(type: :naive_datetime_usec, inserted_at: false)
    end

    create index(:ai_post_embeddings, [:model])
  end

  def down do
    drop table(:ai_post_embeddings)
    execute("DROP EXTENSION IF EXISTS vector")
  end
end
