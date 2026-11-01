defmodule FirestormWeb.Repo.Migrations.AddDeletedAtToUsers do
  use Ecto.Migration

  # Deleted accounts are anonymized in place (see FirestormWeb.AccountDeletion),
  # so their posts and messages keep an author.
  def change do
    alter table(:forums_users) do
      add :deleted_at, :utc_datetime
    end
  end
end
