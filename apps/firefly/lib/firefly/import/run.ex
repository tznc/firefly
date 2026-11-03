defmodule Firefly.Import.Run do
  @moduledoc """
  One run of an importer (see `Firefly.Import`): the source it read, its
  `status` (`"running"`, `"finished"` or `"failed"`, with the `error`),
  whether it was a `dry_run` (everything rolled back at the end), the
  options it was given (secrets left out), what it did per kind of record
  (`counts`: `%{"posts" => %{"imported" => 10, "skipped" => 2, "failed" => 0}}`)
  and the last lines of its log.
  """

  use Ecto.Schema

  @statuses ~w(running finished failed)

  schema "import_runs" do
    field(:source, :string)
    field(:status, :string, default: "running")
    field(:dry_run, :boolean, default: false)
    field(:options, :map, default: %{})
    field(:counts, :map, default: %{})
    field(:log, {:array, :string}, default: [])
    field(:error, :string)
    field(:finished_at, :utc_datetime)

    timestamps(type: :naive_datetime_usec)
  end

  @doc "Every status a run can have."
  def statuses, do: @statuses

  @doc "Whether the run is still going."
  def running?(%__MODULE__{status: status}), do: status == "running"
end
