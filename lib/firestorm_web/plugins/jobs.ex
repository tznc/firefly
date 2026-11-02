defmodule FirestormWeb.Plugins.Jobs do
  @moduledoc """
  Plugins' scheduled jobs: manifest `jobs`, each `{"name", "every"}` (a
  number of seconds, at least 60) or `{"name", "cron"}` (five fields,
  minute hour day-of-month month day-of-week, in UTC; `*`, `*/n`, `a-b`,
  `a-b/n` and lists; day-of-week 0-7 with 0 and 7 Sunday; as in cron, when
  both day fields are restricted either may match).

  Each job's next run time is stored (`FirestormWeb.Plugins.ScheduledJob`),
  so jobs survive restarts and run once across nodes: `run_due/1` takes due
  rows with `SKIP LOCKED` and moves them to their next time before running
  the plugin's `run_job` hook. A run that fails isn't retried; the next
  scheduled run is the retry. A job that fell due several times while the
  app was down runs once.
  """

  import Ecto.Query

  alias FirestormWeb.{Plugin, Plugins, Repo}
  alias FirestormWeb.Plugin.Runner
  alias FirestormWeb.Plugins.ScheduledJob

  @fields [minute: 0..59, hour: 0..23, day: 1..31, month: 1..12, weekday: 0..7]

  @doc false
  def check_definition(%{"name" => name} = job) when is_binary(name) do
    cond do
      not (name =~ ~r/^[a-z][a-z0-9_]{0,39}$/) -> ["job \"#{name}\" needs a lowercase name"]
      Map.keys(job) -- ["name", "every", "cron"] != [] -> ["job \"#{name}\" has unknown keys"]
      match?({:ok, _}, parse(job)) -> []
      true -> ["job \"#{name}\" needs \"every\" (60 seconds or more) or a valid \"cron\""]
    end
  end

  def check_definition(_job), do: ["each job needs a name"]

  @doc "Parses a job's schedule: `{:ok, {:every, seconds}}`, `{:ok, {:cron, fields}}` or `:error`."
  def parse(%{"every" => seconds} = job)
      when is_integer(seconds) and not is_map_key(job, "cron") do
    if seconds in 60..(30 * 86_400), do: {:ok, {:every, seconds}}, else: :error
  end

  def parse(%{"cron" => cron} = job) when is_binary(cron) and not is_map_key(job, "every") do
    with parts when length(parts) == 5 <- String.split(cron),
         sets when not is_map_key(sets, :error) <- cron_sets(parts) do
      {:ok, {:cron, sets}}
    else
      _ -> :error
    end
  end

  def parse(_job), do: :error

  defp cron_sets(parts) do
    Map.new(Enum.zip(@fields, parts), fn {{name, range}, part} ->
      case field_values(part, range) do
        {:ok, values} -> {name, values}
        :error -> {:error, part}
      end
    end)
  end

  defp field_values("*", range), do: {:ok, {:any, range}}

  defp field_values(part, range) do
    part
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn item, {:ok, acc} ->
      case item_values(item, range) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp item_values(item, first..last//1 = range) do
    {span, step} =
      case String.split(item, "/") do
        [span] -> {span, "1"}
        [span, step] -> {span, step}
        _ -> {nil, nil}
      end

    with {step, ""} when step > 0 <- Integer.parse(step || ""),
         {:ok, from, to} <- span(span, first, last),
         true <- from in range and to in range and from <= to do
      {:ok, MapSet.new(Enum.take_every(from..to, step))}
    else
      _ -> :error
    end
  end

  defp span("*", first, last), do: {:ok, first, last}

  defp span(span, _first, _last) when is_binary(span) do
    case Enum.map(String.split(span, "-"), &Integer.parse/1) do
      [{from, ""}] -> {:ok, from, from}
      [{from, ""}, {to, ""}] -> {:ok, from, to}
      _ -> :error
    end
  end

  defp span(_span, _first, _last), do: :error

  @doc "When a job with schedule `schedule` (from `parse/1`) runs next after `from`."
  def next({:every, seconds}, from), do: DateTime.add(from, seconds)

  def next({:cron, sets}, from) do
    start = DateTime.add(%{DateTime.truncate(from, :second) | second: 0}, 60)
    find(sets, start, DateTime.add(start, 366 * 86_400))
  end

  defp find(sets, at, limit) do
    cond do
      DateTime.after?(at, limit) -> limit
      not member?(sets.month, at.month) -> find(sets, next_month(at), limit)
      not day?(sets, at) -> find(sets, next_day(at), limit)
      not member?(sets.hour, at.hour) -> find(sets, next_hour(at), limit)
      not member?(sets.minute, at.minute) -> find(sets, DateTime.add(at, 60), limit)
      true -> at
    end
  end

  # Cron's rule: with both day fields restricted, either may match.
  defp day?(sets, at) do
    weekday = rem(Date.day_of_week(at), 7)
    day = member?(sets.day, at.day)
    week = member?(sets.weekday, weekday) or (weekday == 0 and member?(sets.weekday, 7))

    case {sets.day, sets.weekday} do
      {{:any, _}, _} -> week
      {_, {:any, _}} -> day
      _ -> day or week
    end
  end

  defp member?({:any, _range}, _value), do: true
  defp member?(set, value), do: MapSet.member?(set, value)

  defp next_hour(at), do: %{DateTime.add(at, 3600) | minute: 0}
  defp next_day(at), do: %{DateTime.add(at, 86_400) | hour: 0, minute: 0}

  defp next_month(at) do
    date = at |> DateTime.to_date() |> Date.end_of_month() |> Date.add(1)
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end

  @doc """
  Runs the active plugins' due jobs at `now`, scheduling the ones not yet
  scheduled. Returns how many ran.
  """
  def run_due(now \\ DateTime.utc_now()) do
    plugins = Enum.filter(Plugins.active(), &Plugin.implements?(&1, "run_job"))
    schedule(plugins, now)
    run_next(plugins, now, 0)
  end

  defp schedule(plugins, now) do
    rows =
      for plugin <- plugins, job <- plugin.manifest.jobs, {:ok, schedule} = parse(job) do
        %{plugin_id: plugin.id, job: job["name"], next_run_at: next(schedule, now)}
      end

    Repo.insert_all(ScheduledJob, rows,
      on_conflict: :nothing,
      conflict_target: [:plugin_id, :job]
    )
  end

  defp run_next(plugins, now, count) do
    {:ok, claimed} =
      Repo.transact(fn ->
        ScheduledJob
        |> where([s], s.next_run_at <= ^now)
        |> order_by([s], asc: s.next_run_at, asc: s.id)
        |> limit(1)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()
        |> claim(plugins, now)
      end)

    case claimed do
      :none ->
        count

      :dropped ->
        run_next(plugins, now, count)

      {plugin, job} ->
        Runner.invoke(plugin, "run_job", [%{"job" => job}])
        run_next(plugins, now, count + 1)
    end
  end

  defp claim(nil, _plugins, _now), do: {:ok, :none}

  defp claim(row, plugins, now) do
    plugin = Enum.find(plugins, &(&1.id == row.plugin_id))
    job = plugin && Enum.find(plugin.manifest.jobs, &(&1["name"] == row.job))

    if job do
      {:ok, schedule} = parse(job)
      Repo.update!(Ecto.Changeset.change(row, next_run_at: next(schedule, now)))
      {:ok, {plugin, row.job}}
    else
      # Its plugin is gone, inactive or no longer has the job: scheduled
      # afresh if it comes back.
      Repo.delete!(row)
      {:ok, :dropped}
    end
  end

  @doc "Forgets `plugin_id`'s job schedule (on uninstall)."
  def clear(plugin_id), do: Repo.delete_all(where(ScheduledJob, plugin_id: ^plugin_id))
end
