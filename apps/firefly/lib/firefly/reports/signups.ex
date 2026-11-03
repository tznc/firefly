defmodule Firefly.Reports.Signups do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "signups",
    title: "Signups",
    description: "New accounts per day."

  import Ecto.Query

  @impl true
  def run(range),
    do:
      series(
        "signups",
        "Signups",
        daily(
          count_by_day(
            from(r in "forums_users", where: is_nil(r.deleted_at)),
            :inserted_at,
            range
          ),
          range
        )
      )
end
