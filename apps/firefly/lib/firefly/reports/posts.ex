defmodule Firefly.Reports.Posts do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "posts",
    title: "Posts",
    description: "New posts per day, first posts and replies (deleted ones aren't counted)."

  import Ecto.Query

  @impl true
  def run(range),
    do:
      series(
        "posts",
        "Posts",
        daily(
          count_by_day(
            from(r in "forums_posts", where: is_nil(r.deleted_at)),
            :inserted_at,
            range
          ),
          range
        )
      )
end
