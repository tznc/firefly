defmodule Firefly.Reports.Akismet do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "akismet",
    title: "Akismet",
    description:
      "Content Akismet checked per day, what it called spam, and what staff confirmed or found wasn't."

  import Ecto.Query

  @impl true
  def run(range) do
    {start, stop} = bounds(range)

    rows =
      Firefly.Repo.all(
        from(c in "akismet_checks",
          # Checks Akismet answered.
          where: c.status not in ["queued", "failed"],
          where:
            c.inserted_at >= type(^start, :naive_datetime) and
              c.inserted_at < type(^stop, :naive_datetime),
          group_by: fragment("date(?)", c.inserted_at),
          select: {
            fragment("date(?)", c.inserted_at),
            count(),
            type(sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", c.spam)), :integer),
            type(
              sum(fragment("CASE WHEN ? = 'confirmed' THEN 1 ELSE 0 END", c.status)),
              :integer
            ),
            type(sum(fragment("CASE WHEN ? = 'not_spam' THEN 1 ELSE 0 END", c.status)), :integer)
          }
        )
      )

    {:series,
     [
       %{
         key: "checked",
         label: "Checked",
         points: daily(for({d, n, _, _, _} <- rows, do: {d, n}), range)
       },
       %{
         key: "spam",
         label: "Spam",
         points: daily(for({d, _, n, _, _} <- rows, do: {d, n}), range)
       },
       %{
         key: "confirmed",
         label: "Confirmed spam",
         points: daily(for({d, _, _, n, _} <- rows, do: {d, n}), range)
       },
       %{
         key: "not_spam",
         label: "Not spam",
         points: daily(for({d, _, _, _, n} <- rows, do: {d, n}), range)
       }
     ]}
  end
end
