defmodule Firefly.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  # Browser push subscriptions (see Firefly.WebPush), one per browser
  # (its endpoint), and whether a member wants pushes only while away.
  def change do
    create table(:push_subscriptions) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :endpoint, :text, null: false
      add :p256dh, :string, null: false
      add :auth, :binary, null: false
      add :user_agent, :string
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:user_id])

    alter table(:forums_users) do
      add :push_only_when_away, :boolean, null: false, default: true
    end
  end
end
