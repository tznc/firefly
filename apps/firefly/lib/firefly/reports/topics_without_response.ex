defmodule Firefly.Reports.TopicsWithoutResponse do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "topics_without_response",
    title: "Topics with no response",
    description: "Topics started in the period that nobody but their author has replied to."

  @impl true
  def run(range) do
    {start, stop} = bounds(range)

    %{rows: rows} =
      Firefly.Repo.query!(
        """
        SELECT t.title, c.title, to_char(t.inserted_at, 'YYYY-MM-DD')
        FROM forums_threads t
        JOIN forums_categories c ON c.id = t.category_id
        WHERE t.inserted_at >= $1 AND t.inserted_at < $2 AND t.merged_into_id IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM forums_posts p
            WHERE p.thread_id = t.id AND p.deleted_at IS NULL
              AND p.user_id <> (SELECT f.user_id FROM forums_posts f WHERE f.thread_id = t.id
                                ORDER BY f.inserted_at, f.id LIMIT 1))
        ORDER BY t.inserted_at DESC
        LIMIT 100
        """,
        [start, stop]
      )

    {:table, ["Topic", "Category", "Started"], rows}
  end
end
