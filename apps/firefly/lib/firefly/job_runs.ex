defmodule Firefly.JobRuns do
  @moduledoc """
  When each periodic job last ran (`job_runs`, one row per job), so a job
  run by the scheduler (`Firefly.TopicTimers.Scheduler`) on every
  node runs once per interval in all: `claim/2` takes the run atomically.
  """

  alias Firefly.Repo

  @doc """
  Claims the job named `name` if it last ran over `seconds` ago (or never),
  recording that it runs now. Only one caller wins a claim, whatever the
  number of nodes.
  """
  def claim(name, seconds) do
    now = DateTime.utc_now(:second)

    %{num_rows: rows} =
      Repo.query!(
        """
        INSERT INTO job_runs (name, ran_at) VALUES ($1, $2)
        ON CONFLICT (name) DO UPDATE SET ran_at = EXCLUDED.ran_at
        WHERE job_runs.ran_at <= $3
        """,
        [name, now, DateTime.add(now, -seconds)]
      )

    rows == 1
  end
end
