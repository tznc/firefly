defmodule FirestormWeb.Repo.Migrations.AddWikiToPosts do
  use Ecto.Migration

  # Wiki posts: staff mark a post as a wiki, and then anyone who may post
  # in its thread may edit it (see the :edit_post policy).
  def change do
    alter table(:forums_posts) do
      add :wiki, :boolean, null: false, default: false
    end
  end
end
