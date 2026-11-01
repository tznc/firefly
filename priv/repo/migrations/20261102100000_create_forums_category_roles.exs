defmodule FirestormWeb.Repo.Migrations.CreateForumsCategoryRoles do
  use Ecto.Migration

  # A category with rows here is restricted to members of those roles (see
  # FirestormWeb.Forums.Policy). Deleting a role that restricts a category is
  # refused rather than silently opening the category to everyone.
  def change do
    create table(:forums_category_roles, primary_key: false) do
      add :category_id, references(:forums_categories, on_delete: :delete_all), null: false
      add :role_id, references(:forums_roles, on_delete: :restrict), null: false
    end

    create unique_index(:forums_category_roles, [:category_id, :role_id])
    create index(:forums_category_roles, [:role_id])
    # Every permission check looks up the user's roles.
    create index(:forums_role_memberships, [:user_id])
  end
end
