defmodule FireflyWeb.JobsDashboardTest do
  # Not async: the dashboard's Oban instance is node-wide.
  use FireflyWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Firefly.Moderation.StaffAction
  alias FireflyWeb.JobsDashboard

  setup do: start_jobs_dashboard()

  test "admins get the dashboard", %{conn: conn} do
    html = conn |> log_in_as(admin_fixture()) |> get("/staff/jobs/jobs") |> html_response(200)
    assert html =~ "Oban"
  end

  test "anyone else is turned away", %{conn: conn} do
    assert conn |> get("/staff/jobs/jobs") |> redirected_to() == "/"

    assert conn |> log_in_as(user_fixture()) |> get("/staff/jobs/queues") |> redirected_to() ==
             "/"
  end

  test "rights are re-checked against the database on every mount" do
    admin = admin_fixture()
    member = user_fixture()

    assert JobsDashboard.resolve_access(admin.id) == :all
    assert JobsDashboard.resolve_access(member.id) == {:forbidden, "/"}
    assert JobsDashboard.resolve_access(nil) == {:forbidden, "/"}

    # The session holds only the id: an admin removed since is refused.
    Firefly.Repo.delete!(admin)
    assert JobsDashboard.resolve_access(admin.id) == {:forbidden, "/"}
  end

  test "the dashboard's actions are staff-logged" do
    admin = admin_fixture()

    for {action, meta} <- [
          {:retry_jobs, %{job_ids: [7, 8]}},
          {:cancel_jobs, %{job_ids: [9]}},
          {:scale_queue, %{queue: "mailers", limit: 20}},
          {:pause_all_queues, %{}},
          # Read-only views aren't actions to log.
          {:mount, %{}}
        ] do
      :telemetry.execute(
        [:oban_web, :action, :stop],
        %{duration: 1},
        Map.merge(meta, %{action: action, user: admin.id, config: nil})
      )
    end

    logged =
      Firefly.Repo.all(
        from(a in StaffAction, order_by: a.id, select: {a.action, a.target_type, a.details})
      )

    assert logged == [
             {"job.retry", "job", %{"job_ids" => [7, 8]}},
             {"job.cancel", "job", %{"job_ids" => [9]}},
             {"queue.scale", "queue", %{"queues" => ["mailers"], "limit" => 20}},
             {"queue.pause", "queue", %{"queues" => ["all"]}}
           ]
  end
end
