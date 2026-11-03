defmodule Firefly.Repo.Migrations.AddAIFeatures do
  use Ecto.Migration

  # AI features (see Firefly.AI): cached topic summaries, cached
  # translations of posts and chat messages, and triage's ratings of posts
  # (which the sentiment report counts).
  def change do
    create table(:ai_summaries) do
      add :thread_id, references(:forums_threads, on_delete: :delete_all), null: false
      add :content, :text, null: false
      # How many posts the summary covered: it's made again after enough new ones.
      add :post_count, :integer, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:ai_summaries, [:thread_id])

    create table(:ai_translations) do
      add :post_id, references(:forums_posts, on_delete: :delete_all)
      add :chat_message_id, references(:chat_messages, on_delete: :delete_all)
      add :language, :string, null: false
      # The source text's hash: an edit makes the translation stale.
      add :source_hash, :binary, null: false
      add :content, :text, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:ai_translations, [:post_id, :language], where: "post_id IS NOT NULL")

    create unique_index(:ai_translations, [:chat_message_id, :language],
             where: "chat_message_id IS NOT NULL"
           )

    create constraint(:ai_translations, :one_source,
             check: "num_nonnulls(post_id, chat_message_id) = 1"
           )

    create table(:ai_post_classifications) do
      add :post_id, references(:forums_posts, on_delete: :delete_all), null: false
      add :toxicity, :integer, null: false
      add :spam, :integer, null: false
      add :sentiment, :string, null: false
      add :reason, :text

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create unique_index(:ai_post_classifications, [:post_id])
    create index(:ai_post_classifications, [:inserted_at])
  end
end
