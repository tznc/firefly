defmodule Firefly.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  it cannot be async. For this reason, every test runs
  inside a transaction which is reset at the beginning
  of the test unless the test case is marked as async.
  """

  # Test support, for any app's tests: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Firefly.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Firefly.DataCase

      # Jobs are only enqueued in tests: assert_enqueued/1, perform_job/2.
      use Oban.Testing, repo: Firefly.Repo
    end
  end

  setup tags do
    Firefly.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    # Deep fuzz runs (`:fuzz`, or properties given more runs) hold the
    # sandbox for minutes.
    long? = tags[:fuzz] || System.get_env("FIREFLY_PROPERTY_RUNS")
    timeout = if long?, do: [ownership_timeout: :infinity], else: []

    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Firefly.Repo, [shared: not tags[:async]] ++ timeout)

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    pid
  end

  @doc """
  Runs the notification jobs enqueued so far, in the test's process: the
  fan-out (`Firefly.Notifications.FanOut`), then the emails it queued.
  """
  def run_notifications do
    Oban.drain_queue(queue: :notifications, with_recursion: true)
    Oban.drain_queue(queue: :mailers, with_recursion: true)
    :ok
  end

  @doc """
  A helper that transform changeset errors to a map of messages.

      changeset = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
