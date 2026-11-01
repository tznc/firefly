defmodule FirestormWeb.Repo.Migrations.CreateForumsPolls do
  use Ecto.Migration

  # Polls (see FirestormWeb.Polls): at most one per post, created with it.
  # A vote is one row per option chosen (with its rank, in a ranked-choice
  # poll); changing a vote replaces the user's rows.
  def change do
    create table(:forums_polls) do
      add :post_id, references(:forums_posts, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :min_choices, :integer
      add :max_choices, :integer
      add :results, :string, null: false
      add :public, :boolean, null: false, default: false
      add :close_at, :utc_datetime
      add :closed_at, :utc_datetime

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_polls, [:post_id])

    create index(:forums_polls, [:close_at], where: "close_at IS NOT NULL AND closed_at IS NULL")

    create table(:forums_poll_options) do
      add :poll_id, references(:forums_polls, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :text, :string, size: 200, null: false
    end

    create unique_index(:forums_poll_options, [:poll_id, :position])

    create table(:forums_poll_votes) do
      add :poll_id, references(:forums_polls, on_delete: :delete_all), null: false
      add :option_id, references(:forums_poll_options, on_delete: :delete_all), null: false
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :rank, :integer

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create unique_index(:forums_poll_votes, [:poll_id, :user_id, :option_id])
    create index(:forums_poll_votes, [:user_id])
    create index(:forums_poll_votes, [:option_id])
  end
end
