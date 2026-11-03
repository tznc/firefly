defmodule Firefly.Reports.Penalties do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "penalties",
    title: "Suspensions and silences",
    description: "Members suspended or silenced (and lifted), from the staff log."

  @actions ~w(user.suspend user.unsuspend user.silence user.unsilence)

  import Ecto.Query

  @impl true
  def run(range) do
    {start, stop} = bounds(range)

    rows =
      Firefly.Repo.all(
        from(a in "forums_staff_actions",
          left_join: target in "forums_users",
          on: a.target_type == "user" and target.id == a.target_id,
          left_join: actor in "forums_users",
          on: actor.id == a.actor_id,
          where:
            a.action in ^@actions and a.inserted_at >= type(^start, :naive_datetime) and
              a.inserted_at < type(^stop, :naive_datetime),
          order_by: [desc: a.inserted_at],
          select: [
            fragment("to_char(?, 'YYYY-MM-DD')", a.inserted_at),
            a.action,
            target.username,
            actor.username,
            fragment("?->>'reason'", a.details)
          ]
        )
      )

    {:table, ["Date", "Action", "Member", "By", "Reason"], rows}
  end
end
