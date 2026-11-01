defmodule FirestormWeb.Repo.Migrations.CreateTagGroups do
  use Ecto.Migration

  def change do
    # Named groups of tags (see FirestormWeb.Tags): optionally staff-only,
    # optionally at most one of their tags per thread.
    create table(:forums_tag_groups) do
      add :name, :string, null: false
      add :staff_only, :boolean, null: false, default: false
      add :one_per_thread, :boolean, null: false, default: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:forums_tag_groups, [:name])

    alter table(:forums_tags) do
      add :group_id, references(:forums_tag_groups, on_delete: :nilify_all)
      # A synonym is stored as its canonical tag wherever it's applied.
      add :synonym_of_id, references(:forums_tags, on_delete: :nilify_all)
    end

    create index(:forums_tags, [:group_id])
    create index(:forums_tags, [:synonym_of_id])
  end
end
