defmodule Firefly.Repo.Migrations.CreateAnalytics do
  use Ecto.Migration

  # First-party analytics (see Firefly.Analytics): daily aggregates only.
  # Nothing here holds an IP address: anonymous viewers are a hash salted
  # with a random value that is deleted once its day is over.
  def change do
    create table(:analytics_page_views, primary_key: false) do
      add :date, :date, primary_key: true
      add :kind, :string, primary_key: true
      add :count, :bigint, null: false, default: 0
    end

    create table(:analytics_referrers, primary_key: false) do
      add :date, :date, primary_key: true
      add :domain, :string, primary_key: true
      add :count, :bigint, null: false, default: 0
    end

    create table(:analytics_topic_views, primary_key: false) do
      add :date, :date, primary_key: true

      add :thread_id, references(:forums_threads, on_delete: :delete_all), primary_key: true

      add :count, :bigint, null: false, default: 0
    end

    create index(:analytics_topic_views, [:thread_id])

    # Who viewed which thread today, to count each viewer once a day.
    create table(:analytics_topic_viewers, primary_key: false) do
      add :date, :date, primary_key: true
      add :thread_id, :bigint, primary_key: true
      add :viewer, :string, primary_key: true
    end

    create table(:analytics_link_clicks, primary_key: false) do
      add :post_id, references(:forums_posts, on_delete: :delete_all), primary_key: true
      add :url, :string, size: 2000, primary_key: true
      add :count, :bigint, null: false, default: 0
    end

    create table(:analytics_salts, primary_key: false) do
      add :date, :date, primary_key: true
      add :salt, :binary, null: false
    end

    alter table(:forums_threads) do
      add :views, :bigint, null: false, default: 0
    end
  end
end
