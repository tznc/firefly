defmodule Firefly.Repo.Migrations.AddObanJobs do
  @moduledoc "Oban's jobs table, peers and notify trigger (see Firefly.Jobs)."
  use Ecto.Migration

  # Pinned, so a later Oban upgrade adds its own migration from here.
  def up, do: Oban.Migration.up(version: 14)
  def down, do: Oban.Migration.down(version: 1)
end
