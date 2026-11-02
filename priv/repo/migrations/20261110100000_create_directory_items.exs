defmodule FirestormWeb.Repo.Migrations.CreateDirectoryItems do
  use Ecto.Migration

  # The user directory's stats (see FirestormWeb.Directory): one row per
  # user and period, refreshed periodically rather than aggregated live.
  # Visits (one row per user and day they came, with the posts they read)
  # and `last_seen_at` feed "days visited", "posts read" and profiles.
  def change do
    create table(:directory_items) do
      add :period, :string, null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :likes_received, :integer, null: false, default: 0
      add :likes_given, :integer, null: false, default: 0
      add :topic_count, :integer, null: false, default: 0
      add :post_count, :integer, null: false, default: 0
      add :days_visited, :integer, null: false, default: 0
      add :posts_read, :integer, null: false, default: 0
      add :topics_entered, :integer, null: false, default: 0

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:directory_items, [:period, :user_id])

    create table(:user_visits) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :visited_on, :date, null: false
      add :posts_read, :integer, null: false, default: 0
    end

    create unique_index(:user_visits, [:user_id, :visited_on])

    alter table(:forums_users) do
      add :last_seen_at, :utc_datetime
    end
  end
end
