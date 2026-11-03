defmodule Firefly.Repo.Migrations.AddChatFlagsAndNotifications do
  use Ecto.Migration

  # Chat (see Firefly.Chat): flags on chat messages for the review queue,
  # and notifications about a chat channel (mentions, direct messages).
  def change do
    create table(:chat_message_flags) do
      add :message_id, references(:chat_messages, on_delete: :delete_all), null: false
      # Nil: flagged by the system (a watched word).
      add :user_id, references(:forums_users, on_delete: :delete_all)
      add :reason, :string, null: false
      add :note, :text
      add :status, :string, null: false, default: "pending"
      add :reviewed_by_id, references(:forums_users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:chat_message_flags, [:message_id, :user_id])
    create index(:chat_message_flags, [:status])

    alter table(:forums_notifications) do
      add :chat_channel_id, references(:chat_channels, on_delete: :delete_all)
    end

    create index(:forums_notifications, [:user_id, :chat_channel_id],
             where: "chat_channel_id IS NOT NULL"
           )
  end
end
