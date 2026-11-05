defmodule Firefly.Repo.Migrations.CreateAkismetChecks do
  use Ecto.Migration

  # Akismet checks of new content (see Firefly.Moderation.Akismet), made
  # when it's posted: what to send (the job carries only the row's id),
  # Akismet's verdict once it answers, and what staff decided and told it.
  def change do
    create table(:akismet_checks) do
      add :kind, :string, null: false
      add :subject_id, :bigint, null: false
      add :user_id, references(:forums_users, on_delete: :nilify_all)
      # Nil until Akismet answers.
      add :spam, :boolean
      # "queued" (waiting for Akismet), "clean", "pending" (spam, waiting for
      # staff), "confirmed", "not_spam".
      add :status, :string, null: false
      add :params, :map, null: false, default: %{}
      # What we told Akismet afterwards: "spam" or "ham".
      add :feedback, :string
      add :reviewed_by_id, references(:forums_users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:akismet_checks, [:kind, :subject_id])
    create index(:akismet_checks, [:status])
    create index(:akismet_checks, [:inserted_at])
  end
end
