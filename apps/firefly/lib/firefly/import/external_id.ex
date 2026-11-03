defmodule Firefly.Import.ExternalId do
  @moduledoc false
  # What a source's record (`kind`, `external_id`) became here (`local_id`).

  use Ecto.Schema

  schema "import_ids" do
    field(:source, :string)
    field(:kind, :string)
    field(:external_id, :string)
    field(:local_id, :integer)
    field(:run_id, :id)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
