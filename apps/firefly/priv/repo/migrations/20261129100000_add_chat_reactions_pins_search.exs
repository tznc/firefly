defmodule Firefly.Repo.Migrations.AddChatReactionsPinsSearch do
  use Ecto.Migration

  # Chat (see Firefly.Chat): emoji reactions, pinned messages, and full-text
  # search of messages.
  def up do
    create table(:chat_reactions) do
      add :message_id, references(:chat_messages, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :emoji, :string, null: false

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create unique_index(:chat_reactions, [:message_id, :user_id, :emoji])

    alter table(:chat_messages) do
      add :pinned_at, :utc_datetime
      add :pinned_by_id, references(:forums_users, on_delete: :nilify_all)
    end

    create index(:chat_messages, [:channel_id],
             where: "pinned_at IS NOT NULL",
             name: :chat_messages_pinned_index
           )

    execute """
    ALTER TABLE chat_messages ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (to_tsvector('english', body)) STORED
    """

    create index(:chat_messages, [:search_vector], using: :gin)
  end

  def down do
    drop index(:chat_messages, [:search_vector])
    execute "ALTER TABLE chat_messages DROP COLUMN search_vector"
    drop index(:chat_messages, [:channel_id], name: :chat_messages_pinned_index)

    alter table(:chat_messages) do
      remove :pinned_by_id
      remove :pinned_at
    end

    drop table(:chat_reactions)
  end
end
