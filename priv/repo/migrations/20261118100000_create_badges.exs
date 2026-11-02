defmodule FirestormWeb.Repo.Migrations.CreateBadges do
  use Ecto.Migration

  # Badges (see FirestormWeb.Badges): system badges, granted by the badge
  # job from their queries, and custom ones admins create and grant.
  # A badge granted more than once (`multiple_grant`) is granted once per
  # post; `user_badges` keeps one row per grant.
  def change do
    create table(:badges) do
      add :name, :string, null: false
      add :description, :text, null: false, default: ""
      add :icon, :string, null: false, default: "hero-star"
      add :badge_type, :string, null: false, default: "bronze"
      add :grouping, :string, null: false, default: "other"
      add :enabled, :boolean, null: false, default: true
      add :allow_title, :boolean, null: false, default: false
      add :multiple_grant, :boolean, null: false, default: false
      add :listable, :boolean, null: false, default: true
      # System badges are defined (and granted) by code; admins only switch them.
      add :system, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:badges, ["lower(name)"], name: :badges_lower_name_index)

    create table(:user_badges) do
      add :badge_id, references(:badges, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :granted_by_id, references(:forums_users, on_delete: :nilify_all)
      add :post_id, references(:forums_posts, on_delete: :delete_all)
      add :reason, :text
      add :granted_at, :utc_datetime, null: false
    end

    create index(:user_badges, [:user_id])
    create index(:user_badges, [:badge_id, :granted_at])

    execute(
      "CREATE UNIQUE INDEX user_badges_grant_index ON user_badges (badge_id, user_id, post_id) NULLS NOT DISTINCT",
      "DROP INDEX user_badges_grant_index"
    )

    # The badge a member shows as their title (one that allows it).
    alter table(:forums_users) do
      add :title_badge_id, references(:badges, on_delete: :nilify_all)
    end
  end
end
