defmodule Firefly.Repo.Migrations.DropJobRuns do
  @moduledoc """
  `job_runs` recorded when each periodic task last ran, so one node ran it
  per interval; Oban's cron does that now (see Firefly.Jobs.Periodic).
  """
  use Ecto.Migration

  def up, do: drop(table(:job_runs))

  def down do
    create table(:job_runs, primary_key: false) do
      add :name, :string, primary_key: true
      add :ran_at, :utc_datetime, null: false
    end
  end
end
