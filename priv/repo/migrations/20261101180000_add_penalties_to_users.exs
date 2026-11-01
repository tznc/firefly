defmodule FirestormWeb.Repo.Migrations.AddPenaltiesToUsers do
  use Ecto.Migration

  # Time-boxed penalties: a penalty is in force while its `_until` is in the
  # future, so they lapse on their own (see FirestormWeb.Penalties).
  def change do
    alter table(:forums_users) do
      add :silenced_until, :utc_datetime
      add :silence_reason, :text
      add :suspended_until, :utc_datetime
      add :suspend_reason, :text
    end
  end
end
