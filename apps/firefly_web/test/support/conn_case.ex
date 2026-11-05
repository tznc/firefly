defmodule FireflyWeb.ConnCase do
  @moduledoc """
  The test case for tests that need a connection: controllers and LiveViews.

  Tests run inside a database transaction that is rolled back at the end. If
  the case is not marked async, the transaction is shared with any process
  the test starts (e.g. LiveViews).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint FireflyWeb.Endpoint

      use FireflyWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import PhoenixTest
      import FireflyWeb.ConnCase
      import Firefly.DataCase, only: [run_notifications: 0]
      import Firefly.Fixtures
      import FireflyWeb.ApiHelpers

      # Jobs are only enqueued in tests: assert_enqueued/1, perform_job/2.
      use Oban.Testing, repo: Firefly.Repo
    end
  end

  setup tags do
    Firefly.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Starts the Oban instance the jobs dashboard watches in tests (the app's
  runs in testing mode, without the notifier and stats the dashboard
  needs): no queues or plugins, so it runs nothing. Call from a test that
  isn't async.
  """
  def start_jobs_dashboard do
    ExUnit.Callbacks.start_supervised!(
      {Oban,
       name: FireflyWeb.JobsDashboardOban,
       repo: Firefly.Repo,
       notifier: Oban.Notifiers.Postgres,
       peer: false,
       queues: [],
       plugins: false,
       stager: false}
    )

    :ok
  end

  @doc "Logs `user` in: a new server-side session, its token in the session cookie."
  def log_in_as(conn, user) do
    {token, session} = Firefly.Accounts.UserSessions.create(user)

    Plug.Test.init_test_session(conn, %{
      session_token: token,
      live_socket_id: Firefly.Accounts.UserSessions.live_socket_id(session)
    })
  end

  @doc "The id of the user `conn`'s session cookie is logged in as, or nil."
  def session_user_id(conn) do
    case Firefly.Accounts.UserSessions.get_user(Plug.Conn.get_session(conn, :session_token)) do
      {user, _session} -> user.id
      nil -> nil
    end
  end
end
