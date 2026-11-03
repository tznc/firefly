defmodule Firefly.Repo.Migrations.CreateEmbedding do
  use Ecto.Migration

  # Blog comments (see Firefly.Embedding): the sites allowed to embed
  # topics, and which topic discusses which page.
  def change do
    create table(:embeddable_hosts) do
      add :host, :string, null: false
      add :allowed_paths, {:array, :string}, null: false, default: []
      add :category_id, references(:forums_categories, on_delete: :nilify_all)
      add :class_name, :string
      add :tag, :string

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:embeddable_hosts, [:host])

    create table(:topic_embeds) do
      add :embed_url, :string, size: 2000, null: false
      add :thread_id, references(:forums_threads, on_delete: :delete_all), null: false
      add :host_id, references(:embeddable_hosts, on_delete: :nilify_all)

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:topic_embeds, [:embed_url])
    create index(:topic_embeds, [:thread_id])
  end
end
