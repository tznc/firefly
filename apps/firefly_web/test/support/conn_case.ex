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
      import Firefly.Fixtures
      import FireflyWeb.ApiHelpers
    end
  end

  setup tags do
    Firefly.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Logs `user` in by storing their id in the session."
  def log_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user: user.id})
  end
end
