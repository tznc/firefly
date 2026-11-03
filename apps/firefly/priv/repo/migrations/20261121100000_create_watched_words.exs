defmodule Firefly.Repo.Migrations.CreateWatchedWords do
  use Ecto.Migration

  # Words staff watch for in what members write, each with what happens
  # when it's used (see Firefly.Moderation.WatchedWords). Flags the
  # system raises for a watched word have no flagging member.
  def change do
    create table(:watched_words) do
      add :word, :string, null: false
      add :action, :string, null: false
      add :regex, :boolean, null: false, default: false
      add :replacement, :string
      add :created_by_id, references(:forums_users, on_delete: :nilify_all)

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:watched_words, [:action, "lower(word)"],
             name: :watched_words_action_word_index
           )

    alter table(:forums_post_flags) do
      modify :user_id, :bigint, null: true, from: {:bigint, null: false}
    end
  end
end
