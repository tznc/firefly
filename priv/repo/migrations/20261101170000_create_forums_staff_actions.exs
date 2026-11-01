defmodule FirestormWeb.Repo.Migrations.CreateForumsStaffActions do
  use Ecto.Migration

  # The staff log. Targets are polymorphic (thread, post, category, user...)
  # and outlive their rows, so target_id has no foreign key; `details` keeps
  # what a deleted target looked like.
  def change do
    create table(:forums_staff_actions) do
      add :actor_id, references(:forums_users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :target_type, :string
      add :target_id, :bigint
      add :details, :map, null: false, default: %{}

      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create index(:forums_staff_actions, [:action])
    create index(:forums_staff_actions, [:actor_id])
    create index(:forums_staff_actions, [:target_type, :target_id])
  end
end
