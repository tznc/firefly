defmodule Firefly.Repo.Migrations.CreateChat do
  use Ecto.Migration

  # Chat (see Firefly.Chat): channels (category channels and direct
  # messages), who's in them and how far they've read, messages with their
  # edits, threads and mentions.
  def change do
    create table(:chat_channels) do
      add :kind, :string, null: false
      add :name, :string
      add :slug, :string
      add :description, :text
      add :status, :string, null: false, default: "open"
      # A category channel follows its category's read access; deleting the
      # category deletes its channels.
      add :category_id, references(:forums_categories, on_delete: :delete_all)
      # A direct message channel's members' ids, sorted and joined: the same
      # people always get the same channel.
      add :direct_key, :string
      add :allow_channel_wide_mentions, :boolean, null: false, default: true
      add :last_message_at, :naive_datetime_usec
      add :created_by_id, references(:forums_users, on_delete: :nilify_all)

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:chat_channels, [:slug])
    create unique_index(:chat_channels, [:direct_key])
    create index(:chat_channels, [:category_id])

    create table(:chat_threads) do
      add :channel_id, references(:chat_channels, on_delete: :delete_all), null: false
      add :last_reply_at, :naive_datetime_usec

      timestamps(type: :naive_datetime_usec)
    end

    create index(:chat_threads, [:channel_id])

    create table(:chat_messages) do
      add :body, :text, null: false
      add :channel_id, references(:chat_channels, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :nilify_all)
      add :thread_id, references(:chat_threads, on_delete: :nilify_all)
      add :in_reply_to_id, references(:chat_messages, on_delete: :nilify_all)
      add :edited_at, :utc_datetime
      add :deleted_at, :utc_datetime
      add :deleted_by_id, references(:forums_users, on_delete: :nilify_all)

      timestamps(type: :naive_datetime_usec)
    end

    create index(:chat_messages, [:channel_id, :id])
    create index(:chat_messages, [:thread_id, :id])
    create index(:chat_messages, [:user_id])

    # A thread starts at a message: its original message.
    alter table(:chat_threads) do
      add :original_message_id, references(:chat_messages, on_delete: :delete_all), null: false
    end

    create unique_index(:chat_threads, [:original_message_id])

    create table(:chat_message_revisions) do
      add :message_id, references(:chat_messages, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :nilify_all)
      add :body, :text, null: false

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create index(:chat_message_revisions, [:message_id])

    create table(:chat_memberships) do
      add :channel_id, references(:chat_channels, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :following, :boolean, null: false, default: true
      add :muted, :boolean, null: false, default: false
      add :notification_level, :string, null: false, default: "mention"
      add :last_read_message_id, :bigint

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:chat_memberships, [:channel_id, :user_id])
    create index(:chat_memberships, [:user_id])

    create table(:chat_thread_memberships) do
      add :thread_id, references(:chat_threads, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :last_read_message_id, :bigint

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:chat_thread_memberships, [:thread_id, :user_id])

    create table(:chat_mentions) do
      add :message_id, references(:chat_messages, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create unique_index(:chat_mentions, [:message_id, :user_id])
    create index(:chat_mentions, [:user_id])

    # Files in chat messages are read by whoever may read the channel.
    alter table(:uploads) do
      add :chat_message_id, references(:chat_messages, on_delete: :nilify_all)
    end
  end
end
