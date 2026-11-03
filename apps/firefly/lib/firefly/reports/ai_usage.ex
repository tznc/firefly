defmodule Firefly.Reports.AIUsage do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "ai_usage",
    title: "AI usage",
    description: "Tokens sent to and received from AI providers per day, every feature together."

  import Ecto.Query

  @impl true
  def run(range) do
    rows =
      Firefly.Repo.all(
        from(u in "ai_usage",
          where: u.day >= ^range.from and u.day <= ^range.to,
          group_by: u.day,
          select:
            {u.day, type(sum(u.input_tokens), :integer), type(sum(u.output_tokens), :integer),
             type(sum(u.requests), :integer)}
        )
      )

    {:series,
     [
       %{
         key: "requests",
         label: "Requests",
         points: daily(for({d, _, _, n} <- rows, do: {d, n}), range)
       },
       %{
         key: "input",
         label: "Tokens in",
         points: daily(for({d, i, _, _} <- rows, do: {d, i}), range)
       },
       %{
         key: "output",
         label: "Tokens out",
         points: daily(for({d, _, o, _} <- rows, do: {d, o}), range)
       }
     ]}
  end
end
