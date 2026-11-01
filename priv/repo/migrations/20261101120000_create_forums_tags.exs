defmodule FirestormWeb.Repo.Migrations.CreateForumsTags do
  use Ecto.Migration

  # Tags on threads, and per-user notification levels for tags (like the
  # category levels).
  def change do
    create table(:forums_tags) do
      add :name, :string, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_tags, [:name])

    create table(:forums_threads_tags, primary_key: false) do
      add :thread_id, references(:forums_threads, on_delete: :delete_all), null: false
      add :tag_id, references(:forums_tags, on_delete: :delete_all), null: false
    end

    create unique_index(:forums_threads_tags, [:thread_id, :tag_id])
    create index(:forums_threads_tags, [:tag_id])

    create table(:forums_tags_watches) do
      add :assoc_id, references(:forums_tags, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :level, :string, null: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_tags_watches, [:user_id, :assoc_id])
    create index(:forums_tags_watches, [:assoc_id])
  end
end
