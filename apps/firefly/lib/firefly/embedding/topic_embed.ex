defmodule Firefly.Embedding.TopicEmbed do
  @moduledoc "The topic (thread) discussing an embedded page (see `Firefly.Embedding`)."
  use Ecto.Schema

  alias Firefly.Discussion.Thread
  alias Firefly.Embedding.EmbeddableHost

  schema "topic_embeds" do
    field(:embed_url, :string)
    belongs_to(:thread, Thread)
    belongs_to(:host, EmbeddableHost)

    timestamps(type: :naive_datetime_usec)
  end
end
