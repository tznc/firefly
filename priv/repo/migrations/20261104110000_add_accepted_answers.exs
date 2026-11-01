defmodule FirestormWeb.Repo.Migrations.AddAcceptedAnswers do
  use Ecto.Migration

  # Q&A threads (see FirestormWeb.Solved): a category may allow accepted
  # answers, and a thread there points at the reply accepted as its answer.
  def change do
    alter table(:forums_categories) do
      add :allow_accepted_answers, :boolean, null: false, default: false
    end

    alter table(:forums_threads) do
      add :accepted_post_id, references(:forums_posts, on_delete: :nilify_all)
    end

    create index(:forums_threads, [:accepted_post_id], where: "accepted_post_id IS NOT NULL")
  end
end
