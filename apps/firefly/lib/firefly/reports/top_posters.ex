defmodule Firefly.Reports.TopPosters do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "top_posters",
    title: "Top posters",
    description: "Members who posted the most."

  import Ecto.Query

  @impl true
  def run(range) do
    {start, stop} = bounds(range)

    rows =
      Firefly.Repo.all(
        from(p in "forums_posts",
          join: user in "forums_users",
          on: user.id == p.user_id,
          where:
            is_nil(p.deleted_at) and p.inserted_at >= type(^start, :naive_datetime) and
              p.inserted_at < type(^stop, :naive_datetime),
          group_by: user.username,
          order_by: [desc: count(), asc: user.username],
          limit: 50,
          select: [user.username, count()]
        )
      )

    {:table, ["Member", "Posts"], rows}
  end
end
