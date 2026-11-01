defmodule FirestormWeb.Repo.Migrations.CreateForumsPostFlags do
  use Ecto.Migration

  def change do
    create table(:forums_post_flags) do
      add :post_id, references(:forums_posts, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :reason, :string, null: false
      add :note, :text
      # pending until staff review it: agreed, disagreed or deferred.
      add :status, :string, null: false, default: "pending"
      add :reviewed_by_id, references(:forums_users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_post_flags, [:post_id, :user_id])
    create index(:forums_post_flags, [:status])

    # Set when enough members flag the post: hidden pending staff review.
    alter table(:forums_posts) do
      add :hidden_at, :utc_datetime
    end
  end
end
