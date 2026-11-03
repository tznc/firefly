defmodule Firefly.Reports.TrustLevels do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "trust_levels",
    title: "Trust level distribution",
    description: "Members at each trust level now (whatever the period)."

  import Ecto.Query

  @impl true
  def run(_range) do
    rows =
      Firefly.Repo.all(
        from(u in "forums_users",
          where: is_nil(u.deleted_at),
          group_by: u.trust_level,
          order_by: u.trust_level,
          select: [u.trust_level, count()]
        )
      )

    {:table, ["Trust level", "Members"], rows}
  end
end
