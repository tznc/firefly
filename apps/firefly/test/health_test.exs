defmodule Firefly.HealthTest do
  use Firefly.DataCase, async: true

  alias Firefly.{Health, Repo}

  test "a healthy node is ready" do
    checks = Health.readiness()

    assert checks.database == %{ok: true}
    assert checks.migrations == %{ok: true}
    assert Health.ready?(checks)
  end

  test "without a database connection, the database and migrations checks fail" do
    # A process the sandbox doesn't know gets no connection, as with a
    # database that's down.
    checks = without_connection(&Health.readiness/0)

    refute checks.database.ok
    assert checks.database.error =~ "cannot find ownership process"
    assert checks.migrations == %{ok: false, error: "database down"}
    refute Health.ready?(checks)
  end

  test "a pending migration fails the migrations check" do
    %{rows: [[version]]} = Repo.query!("SELECT max(version) FROM schema_migrations")
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])

    checks = Health.readiness()

    assert checks.migrations == %{ok: false, pending: [version]}
    refute Health.ready?(checks)
  end

  test "read-only mode and the plugin sandbox never fail readiness" do
    checks = %{Health.readiness() | read_only: %{ok: true, enabled: true}}
    assert Health.ready?(checks)
  end

  defp without_connection(fun) do
    parent = self()
    spawn(fn -> send(parent, {:result, fun.()}) end)
    assert_receive {:result, result}, 5_000
    result
  end
end
