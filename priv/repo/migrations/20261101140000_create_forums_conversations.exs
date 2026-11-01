defmodule FirestormWeb.Repo.Migrations.CreateForumsConversations do
  use Ecto.Migration

  # Private messages live in their own tables rather than as flagged threads,
  # so no thread list, search, feed or API can leak them by omission.
  def change do
    create table(:forums_conversations) do
      add :title, :string, null: false
      add :user_id, references(:forums_users, on_delete: :nilify_all)
      add :last_message_at, :naive_datetime_usec, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create table(:forums_conversation_participants) do
      add :conversation_id, references(:forums_conversations, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :last_read_message_id, :bigint
      add :left_at, :utc_datetime

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_conversation_participants, [:user_id, :conversation_id])
    create index(:forums_conversation_participants, [:conversation_id])

    create table(:forums_messages) do
      add :conversation_id, references(:forums_conversations, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :nilify_all)
      add :body, :text, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create index(:forums_messages, [:conversation_id, :id])
    create index(:forums_messages, [:user_id])

    alter table(:forums_notifications) do
      add :conversation_id, references(:forums_conversations, on_delete: :delete_all)
    end

    create index(:forums_notifications, [:conversation_id])

    alter table(:forums_users) do
      add :allow_private_messages, :boolean, null: false, default: true
    end
  end
end
