defmodule FirestormWeb.Repo.Migrations.ThreadStatusAndCategoryFields do
  use Ecto.Migration

  # Thread moderation (pin / close / archive) and richer categories
  # (description, color, position, one level of subcategories).
  def change do
    alter table(:forums_threads) do
      add :pinned_at, :utc_datetime
      add :closed_at, :utc_datetime
      add :archived_at, :utc_datetime
    end

    alter table(:forums_categories) do
      add :description, :text
      add :color, :string
      add :position, :integer, null: false, default: 0
      add :parent_id, references(:forums_categories, on_delete: :nilify_all)
    end

    create index(:forums_categories, [:parent_id])
  end
end
