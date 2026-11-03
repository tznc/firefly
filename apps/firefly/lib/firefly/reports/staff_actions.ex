defmodule Firefly.Reports.StaffActions do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "staff_actions",
    title: "Staff actions",
    description: "What each staff member did, by action, from the staff log."

  import Ecto.Query

  @impl true
  def run(range) do
    {start, stop} = bounds(range)

    rows =
      Firefly.Repo.all(
        from(a in "forums_staff_actions",
          left_join: actor in "forums_users",
          on: actor.id == a.actor_id,
          where:
            a.inserted_at >= type(^start, :naive_datetime) and
              a.inserted_at < type(^stop, :naive_datetime),
          group_by: [actor.username, a.action],
          order_by: [desc: count(), asc: a.action],
          select: [coalesce(actor.username, "system"), a.action, count()]
        )
      )

    {:table, ["Staff member", "Action", "Count"], rows}
  end
end
