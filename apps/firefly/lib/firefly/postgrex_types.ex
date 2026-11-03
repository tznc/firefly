# The Postgres types the repo knows: Ecto's, and pgvector's `vector` (see
# Firefly.AI.SemanticSearch).
Postgrex.Types.define(
  Firefly.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
