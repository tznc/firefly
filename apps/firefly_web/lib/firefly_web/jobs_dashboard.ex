defmodule FireflyWeb.JobsDashboard do
  @moduledoc """
  The background jobs dashboard at `/staff/jobs`: Oban Web (open source,
  Apache-2.0) mounted in the router, for admins (`:manage_jobs`). Its
  queues, jobs and their errors, with retry, cancel, delete and queue
  controls.

  Access is checked on every HTTP request (the `:jobs_admin` pipeline's
  `FireflyWeb.Plugs.RequireAdmin`) and again, against the database, on every
  LiveView mount (`resolve_access/1`), so revoking an admin locks them out
  at their next page or reconnect. Every write action is staff-logged
  (`attach/0`), from Oban Web's telemetry.
  """
  @behaviour Oban.Web.Resolver

  import FireflyWeb.Authorization, only: [can?: 2]

  alias Firefly.Accounts
  alias Firefly.Moderation.StaffLog

  # Oban Web's actions, as staff log actions and their targets.
  @actions %{
    retry_jobs: "job.retry",
    cancel_jobs: "job.cancel",
    delete_jobs: "job.delete",
    pause_queue: "queue.pause",
    pause_queues: "queue.pause",
    pause_all_queues: "queue.pause",
    resume_queue: "queue.resume",
    resume_queues: "queue.resume",
    resume_all_queues: "queue.resume",
    scale_queue: "queue.scale",
    stop_queues: "queue.stop"
  }

  @impl Oban.Web.Resolver
  # The id only: access is decided afresh from the database (below).
  def resolve_user(conn), do: conn.assigns[:current_user] && conn.assigns.current_user.id

  @impl Oban.Web.Resolver
  def resolve_access(user_id) do
    user = user_id && Accounts.get_user(user_id)

    if user && can?(user, :manage_jobs) && not Accounts.TwoFactor.must_enroll?(user),
      do: :all,
      else: {:forbidden, "/"}
  end

  @impl Oban.Web.Resolver
  def resolve_refresh(_user), do: 5

  @doc "Staff-logs the dashboard's write actions. Called once, as the web app starts."
  def attach do
    :telemetry.attach(__MODULE__, [:oban_web, :action, :stop], &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(_event, _measurements, %{action: action, user: user_id} = meta, _config) do
    with {:ok, log_action} <- Map.fetch(@actions, action),
         %{} = admin <- user_id && Accounts.get_user(user_id) do
      StaffLog.record(admin, log_action, target(meta), details(meta))
    end

    :ok
  end

  defp target(%{job_ids: _}), do: {"job", nil}
  defp target(_meta), do: {"queue", nil}

  defp details(%{job_ids: ids}), do: %{job_ids: ids}
  defp details(%{queue: queue, limit: limit}), do: %{queues: [queue], limit: limit}
  defp details(%{queue: queue}), do: %{queues: [queue]}
  defp details(%{queues: queues}), do: %{queues: queues}
  defp details(_all), do: %{queues: ["all"]}
end
