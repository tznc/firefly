defmodule FirestormWeb.Plugins.ScheduledJob do
  @moduledoc """
  When a plugin's scheduled job (manifest `jobs`) runs next (see
  `FirestormWeb.Plugins.Jobs`).
  """
  use Ecto.Schema

  schema "plugin_schedules" do
    field(:plugin_id, :string)
    field(:job, :string)
    field(:next_run_at, :utc_datetime_usec)
  end
end
