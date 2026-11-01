defmodule FirestormWeb.Web.ConnCase do
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
      @endpoint FirestormWeb.Web.Endpoint

      use FirestormWeb.Web, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import PhoenixTest
      import FirestormWeb.Web.ConnCase
    end
  end

  setup tags do
    FirestormWeb.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Logs `user` in by storing their id in the session."
  def log_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user: user.id})
  end

  @doc "Creates a user with sensible defaults."
  def user_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      attrs
      |> Enum.into(%{
        username: "user#{unique}",
        email: "user#{unique}@example.com",
        name: "User #{unique}"
      })
      |> FirestormWeb.Forums.create_user()

    user
  end

  @doc "Creates a category."
  def category_fixture(title \\ "Elixir") do
    {:ok, category} = FirestormWeb.Forums.create_category(%{title: title})
    category
  end

  @doc "Creates a thread (with its first post) in `category` by `user`."
  def thread_fixture(category, user, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{title: "OTP is cool", body: "Don't you think?"})
    {:ok, thread} = FirestormWeb.Forums.create_thread(category, user, attrs)
    thread
  end
end
