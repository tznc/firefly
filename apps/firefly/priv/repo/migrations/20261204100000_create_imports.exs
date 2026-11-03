defmodule Firefly.Repo.Migrations.CreateImports do
  use Ecto.Migration

  # Imports from other forums and chat platforms (see Firefly.Import):
  #
  #   * import_runs: each run of an importer, with its progress and log
  #   * import_ids: what each imported record became (source, kind and its
  #     id there => our id), which makes runs idempotent and resumable
  #   * permalinks: the old site's URLs, redirected to what they became
  def change do
    create table(:import_runs) do
      add :source, :string, null: false
      add :status, :string, null: false, default: "running"
      add :dry_run, :boolean, null: false, default: false
      add :options, :map, null: false, default: %{}
      add :counts, :map, null: false, default: %{}
      add :log, {:array, :text}, null: false, default: []
      add :error, :text
      add :finished_at, :utc_datetime

      timestamps(type: :naive_datetime_usec)
    end

    create index(:import_runs, [:inserted_at])

    create table(:import_ids) do
      add :source, :string, null: false
      add :kind, :string, null: false
      add :external_id, :string, null: false
      add :local_id, :bigint, null: false
      add :run_id, references(:import_runs, on_delete: :nilify_all)

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create unique_index(:import_ids, [:source, :kind, :external_id])
    create index(:import_ids, [:kind, :local_id])
    create index(:import_ids, [:run_id])

    create table(:permalinks) do
      add :url, :text, null: false
      add :source, :string
      add :thread_id, references(:forums_threads, on_delete: :delete_all)
      add :post_id, references(:forums_posts, on_delete: :delete_all)
      add :category_id, references(:forums_categories, on_delete: :delete_all)
      add :user_id, references(:forums_users, on_delete: :delete_all)
      add :tag_id, references(:forums_tags, on_delete: :delete_all)
      add :external_url, :text

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:permalinks, [:url])

    create constraint(:permalinks, :one_target,
             check:
               "num_nonnulls(thread_id, post_id, category_id, user_id, tag_id, external_url) = 1"
           )
  end
end
