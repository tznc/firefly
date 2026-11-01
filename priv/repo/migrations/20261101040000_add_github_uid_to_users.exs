defmodule FirestormWeb.Repo.Migrations.AddGithubUidToUsers do
  use Ecto.Migration

  # GitHub logins are linked to accounts by GitHub's immutable user id, not by
  # username (which anyone can register or rename to).
  def change do
    alter table(:forums_users) do
      add :github_uid, :string
    end

    create unique_index(:forums_users, [:github_uid])
  end
end
