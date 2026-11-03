defmodule Firefly.Reports.TopUploaders do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "top_uploaders",
    title: "Top uploaders",
    description: "Members who uploaded the most, by total size."

  import Ecto.Query

  @impl true
  def run(range) do
    {start, stop} = bounds(range)

    rows =
      Firefly.Repo.all(
        from(u in "uploads",
          join: user in "forums_users",
          on: user.id == u.user_id,
          where:
            u.inserted_at >= type(^start, :naive_datetime) and
              u.inserted_at < type(^stop, :naive_datetime),
          group_by: user.username,
          order_by: [desc: sum(u.size), asc: user.username],
          limit: 50,
          select: [user.username, count(), type(sum(u.size), :integer)]
        )
      )

    {:table, ["Member", "Files", "Bytes"], rows}
  end
end
